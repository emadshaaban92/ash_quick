defmodule AshQuick.StorageTest do
  use ExUnit.Case, async: true

  alias AshQuick.AshTypes.Attachment.Value
  alias AshQuick.Storage
  alias AshQuick.Test.Uploads.ObjectStore

  describe "the storage seam" do
    # `:storage` is `AshQuick.Test.Uploads.ObjectStore`, which names a bucket of
    # its own. AshQuick's `:s3_bucket` is set to something else in
    # `config/test.exs` precisely so that a URL built from it would be visible
    # here: the host's seam is what serves attachments, and the library holds
    # no second opinion about which bucket the object is in.
    test "attachment URLs come from the configured seam, not AshQuick's own bucket" do
      value = %Value{key: "public/products/abc.jpg", file_type: :image}

      assert {:ok, url} = Storage.url_for(value)
      assert url =~ ObjectStore.bucket()
      refute url =~ AshQuick.Config.s3_bucket()
    end

    test "the default implementation resolves its own bucket for a host that sets none" do
      assert AshQuick.Storage.S3.public_url("public/x.jpg") ==
               "https://#{AshQuick.Config.s3_bucket()}.#{AshQuick.Config.s3_host()}/public/x.jpg"
    end
  end

  describe "url_for/2" do
    test "public/* keys produce a deterministic HTTPS URL against the configured host+bucket" do
      bucket = ObjectStore.bucket()
      host = ObjectStore.host()
      value = %Value{key: "public/products/abc-photo.jpg", file_type: :image}

      assert Storage.url_for(value) ==
               {:ok, "https://#{bucket}.#{host}/public/products/abc-photo.jpg"}
    end

    test "public/* keys with unsafe characters are URL-encoded per path segment" do
      bucket = ObjectStore.bucket()
      host = ObjectStore.host()
      # Legacy key uploaded before filenames were slugified.
      value = %Value{key: "public/products/abc-My Vacation (1).jpg", file_type: :image}

      assert Storage.url_for(value) ==
               {:ok, "https://#{bucket}.#{host}/public/products/abc-My%20Vacation%20%281%29.jpg"}
    end

    test "public/* URLs ignore :expires_in (no signing)" do
      value = %Value{key: "public/products/abc.jpg", file_type: :image}
      assert Storage.url_for(value) == Storage.url_for(value, expires_in: 60)
    end

    test "private/* keys produce a presigned GET URL with a signature" do
      value = %Value{key: "private/return_requests/abc-video.mp4", file_type: :video}
      {:ok, url} = Storage.url_for(value)

      assert String.contains?(url, "private/return_requests/abc-video.mp4")
      assert String.contains?(url, "X-Amz-Signature") or String.contains?(url, "Signature=")
    end

    test "private/* URLs respect :expires_in" do
      value = %Value{key: "private/return_requests/abc.mp4", file_type: :video}

      {:ok, url_short} = Storage.url_for(value, expires_in: 60)
      {:ok, url_long} = Storage.url_for(value, expires_in: 3600)

      # The presigned URL encodes the expiry, so the two URLs must differ.
      assert url_short != url_long
    end

    # The property a quarantine prefix leans on: nesting `public/` under it does
    # not produce a public URL, because the match is anchored. This holds with
    # no gate in front of it at all, which is why the nesting is safe.
    test "a public/ key nested under another prefix is signed, not served publicly" do
      bucket = ObjectStore.bucket()
      host = ObjectStore.host()
      value = %Value{key: "quarantine/public/products/abc.jpg", file_type: :image}

      {:ok, url} = Storage.url_for(value)

      refute url == "https://#{bucket}.#{host}/quarantine/public/products/abc.jpg"
      assert String.contains?(url, "X-Amz-Signature") or String.contains?(url, "Signature=")
    end

    test "an unknown variant is refused rather than silently served as the original" do
      value = %Value{key: "public/products/abc.jpg", file_type: :image}

      assert_raise ArgumentError, ~r/unknown attachment variant :thumb/, fn ->
        Storage.url_for(value, variant: :thumb)
      end
    end
  end

  describe "url_for/2 with prefetched states" do
    setup do
      %{value: %Value{key: "public/products/abc.jpg", file_type: :image}}
    end

    test "withholds the URL for an object the host is still holding", %{value: value} do
      assert Storage.url_for(value, states: %{value.key => :processing}) == :processing
      assert Storage.url_for(value, states: %{value.key => :rejected}) == :rejected
    end

    test "serves an object the host has released", %{value: value} do
      assert {:ok, _url} = Storage.url_for(value, states: %{value.key => :ready})
    end

    # A prefetched map is the whole batch, so a key missing from it means the
    # host holds no state for that object — not that it wasn't fetched.
    test "serves a key the prefetched batch has no state for", %{value: value} do
      assert {:ok, _url} = Storage.url_for(value, states: %{})
    end
  end
end
