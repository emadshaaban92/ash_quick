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

  describe "download_url/2" do
    test "forces a download under the given filename" do
      url = Storage.download_url("exports/u/products-26-11-07.csv", filename: "products.csv")

      assert url =~ ObjectStore.bucket()
      params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert params["response-content-disposition"] ==
               ~s(attachment; filename="products.csv"; filename*=UTF-8''products.csv)

      assert params["X-Amz-Signature"]
    end

    # The plain `filename` is a quoted string, so a quote in the name would end
    # it early; the exact name rides `filename*`, percent-encoded.
    test "keeps quotes and non-ASCII out of the plain filename" do
      url = Storage.download_url("exports/u/x.csv", filename: ~s(منتجات "q".csv))
      params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert params["response-content-disposition"] =~ ~s(filename="______ _q_.csv")

      assert params["response-content-disposition"] =~
               "filename*=UTF-8''" <> URI.encode(~s(منتجات "q".csv), &URI.char_unreserved?/1)
    end

    test "requires a filename" do
      assert_raise ArgumentError, ~r/:filename/, fn ->
        Storage.download_url("exports/u/x.csv", [])
      end
    end
  end

  describe "upload_target/2" do
    test "the default store takes uploads externally, through the S3 uploader" do
      assert Storage.upload_mode() == :external

      assert {:external, "S3", %{url: url}} =
               Storage.upload_target("public/products/a.jpg", content_length: 12)

      assert url =~ ObjectStore.bucket()
      params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert "content-length" in String.split(params["X-Amz-SignedHeaders"], ";")
    end
  end

  describe "AshQuick.Storage.S3 against an S3-compatible endpoint" do
    @minio [scheme: "http://", host: "minio.internal", port: 9000]

    test "signs virtual-hosted URLs unless the ExAws config says otherwise" do
      private = AshQuick.Storage.S3.url("private/a b.pdf", bucket: "b", ex_aws: @minio)
      assert private =~ ~r{^http://b\.minio\.internal:9000/private/a%20b\.pdf\?X-Amz-}

      path_style = [bucket: "b", ex_aws: [virtual_host: false] ++ @minio]

      assert AshQuick.Storage.S3.url("private/a b.pdf", path_style) =~
               ~r{^http://minio\.internal:9000/b/private/a%20b\.pdf\?X-Amz-}

      assert {:external, "S3", %{url: put}} =
               AshQuick.Storage.S3.upload_target("private/a.png", path_style)

      assert put =~ ~r{^http://minio\.internal:9000/b/private/a\.png\?X-Amz-}

      assert AshQuick.Storage.S3.download_url("x.csv", [filename: "x.csv"] ++ path_style) =~
               ~r{^http://minio\.internal:9000/b/x\.csv\?}
    end

    test "builds public URLs against the ExAws endpoint when no host is named" do
      opts = [bucket: "b", host: nil, ex_aws: @minio]

      assert AshQuick.Storage.S3.public_url("public/a b.png", opts) ==
               "http://b.minio.internal:9000/public/a%20b.png"

      assert AshQuick.Storage.S3.public_url(
               "public/a.png",
               Keyword.update!(opts, :ex_aws, &[{:virtual_host, false} | &1])
             ) == "http://minio.internal:9000/b/public/a.png"

      assert AshQuick.Storage.S3.public_url("public/a.png", bucket: "b", host: nil) ==
               "https://b.s3.amazonaws.com/public/a.png"
    end

    test "a named host serves public URLs over https, in the configured style" do
      opts = [bucket: "b", host: "cdn.example.com", ex_aws: [virtual_host: false] ++ @minio]

      assert AshQuick.Storage.S3.public_url("public/a.png", opts) ==
               "https://cdn.example.com/b/public/a.png"
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

  describe "keys_in/1" do
    # What a form checks a post against and what a save references, so a key
    # a value can hold anywhere has to be found.
    test "finds a key inside a union and a typed map, as well as a list" do
      a = %Value{key: "private/x/a.pdf", file_type: :document}
      b = %Value{key: "private/x/b.jpg", file_type: :image}

      assert Storage.keys_in([%Ash.Union{type: :file, value: a}]) == ["private/x/a.pdf"]
      assert Storage.keys_in(%{"cover" => b, "note" => "text"}) == ["private/x/b.jpg"]
      assert Storage.keys_in(%Ash.Union{type: :text, value: "private/x/a.pdf"}) == []
    end
  end
end
