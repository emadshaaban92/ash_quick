defmodule AshQuick.LiveView.FormUtilsTest do
  @moduledoc """
  What a presign produces: the serving key the record will hold, the write key
  the browser is sent to, and the custody row the host opened for it.

  The key derivation and the traversal guard are pinned here rather than
  through a page because none of it is user-visible — nothing on screen can
  tell you `Content-Length` was signed. The rest of the surface is driven
  through the real form in `ExampleWeb.UploadScenarioTest`.

  It needs a host twice over: the custody row is a real insert, and the URL is
  signed against the bucket `Example.Uploads.ObjectStore` names.
  """
  use Example.DataCase, async: true

  import Example.Test.PresignHelpers

  alias AshQuick.LiveView.FormUtils
  alias Example.Uploads.FileObject
  alias Example.Uploads.Quarantine

  @image_field [visibility: :public, accepts: [:image], max_size_mb: 10]
  @evidence_field [visibility: :private, accepts: [:image, :video], max_size_mb: 50]

  describe "presign_attachment_upload/3" do
    test ":public visibility produces a `public/{plural}/{uuid}-{filename}` serving key",
         %{admin: admin} do
      entry = entry(uuid: "abc-123", client_name: "photo.jpg")

      {:ok, %{key: key, url: url, uploader: "S3"}, _socket} =
        FormUtils.presign_attachment_upload(entry, socket(), @image_field)

      # The bytes go to quarantine; the record stores the serving key, and the
      # row the host opened is keyed by that one.
      assert key == "quarantine/public/products/abc-123-photo.jpg"
      assert String.contains?(url, "quarantine/public/products/abc-123-photo.jpg")

      assert {:ok, [file_object]} =
               FileObject.by_keys(["public/products/abc-123-photo.jpg"], actor: admin)

      assert file_object.state == :processing
    end

    test "slugifies the filename so the key (and URL) carry no unsafe characters" do
      entry = entry(uuid: "abc-123", client_name: "My Vacation Photo (1).JPG")

      {:ok, %{key: key}, _socket} =
        FormUtils.presign_attachment_upload(entry, socket(), @image_field)

      assert key == Quarantine.key("public/products/abc-123-my-vacation-photo-1.jpg")
    end

    test "falls back to a generic name when slugifying leaves nothing" do
      entry = entry(uuid: "abc-123", client_name: "الصورة.png", client_type: "image/png")

      {:ok, %{key: key}, _socket} =
        FormUtils.presign_attachment_upload(entry, socket(), @image_field)

      assert key == Quarantine.key("public/products/abc-123-file.png")
    end

    test ":private visibility produces a `private/{plural}/{uuid}-{filename}` serving key" do
      socket = socket(resource: Example.Catalog.Category)
      entry = entry(uuid: "xyz-789", client_name: "evidence.mp4", client_type: "video/mp4")

      {:ok, %{key: key}, _socket} =
        FormUtils.presign_attachment_upload(entry, socket, @evidence_field)

      assert key == Quarantine.key("private/categories/xyz-789-evidence.mp4")
    end

    test "the presigned URL signs the entry's size as a header, and its type as a param" do
      entry = entry(uuid: "abc", client_name: "x.jpg", client_size: 4_242)

      {:ok, %{url: url}, _socket} =
        FormUtils.presign_attachment_upload(entry, socket(), @image_field)

      # `max_file_size` is a browser-side cap. The length is the server-side
      # one, and only because it is a signed *header* — S3 ignores a query
      # parameter it does not recognise, so a `Content-Length` in the query
      # string would cap nothing.
      assert signed_headers(url) == ["content-length", "host"]
      assert signature(url) == signature_for_length(url, 4_242)
      refute signature(url) == signature_for_length(url, 4_243)

      # Signed, so the client cannot alter it — but unenforced, since S3 does
      # not read it. It does not bind what the object is stored as.
      assert query(url)["Content-Type"] == "image/jpeg"
    end

    test "a path-traversal client_name cannot escape the visibility prefix" do
      socket = socket(resource: Example.Catalog.Category)

      entry =
        entry(uuid: "xyz-789", client_name: "../../public/evil.html", client_type: "text/html")

      {:ok, %{key: key}, _socket} =
        FormUtils.presign_attachment_upload(entry, socket, @evidence_field)

      # `Path.basename` discards every directory component, so the object stays
      # under `private/` and never lands in the anonymously-readable `public/` —
      # nested under `quarantine/` until it is released.
      assert key == "quarantine/private/categories/xyz-789-evil.html"
      refute String.contains?(key, "..")
      assert String.starts_with?(key, "quarantine/private/categories/")
    end

    # The host holds only a key afterwards, and a key cannot be asked what its
    # field accepts — so the field's expectations have to be captured here.
    test "the field's expectations and the actor travel with the object", %{admin: admin} do
      product = %Example.Catalog.Product{id: Ash.UUID.generate()}
      socket = socket(record: product, scope: Example.Scope.new(actor: admin))
      entry = entry(uuid: "cap-1", client_name: "hoodie.jpg")

      {:ok, _meta, _socket} = FormUtils.presign_attachment_upload(entry, socket, @image_field)

      assert {:ok, [file_object]} =
               FileObject.by_keys(["public/products/cap-1-hoodie.jpg"], actor: admin)

      assert file_object.source == :upload_form
      assert file_object.accepts == [:image]
      assert file_object.max_bytes == 10 * 1024 * 1024
      assert file_object.actor_id == admin.id
      assert file_object.resource_name == :product
      assert file_object.original_filename == "hoodie.jpg"
      # An update form knows the record; a create form does not, which is why
      # the link is stamped again at save.
      assert file_object.resource_id == product.id
    end

    test "a create form has no record to point at yet", %{admin: admin} do
      entry = entry(uuid: "new-1", client_name: "hoodie.jpg")

      {:ok, _meta, _socket} = FormUtils.presign_attachment_upload(entry, socket(), @image_field)

      assert {:ok, [file_object]} =
               FileObject.by_keys(["public/products/new-1-hoodie.jpg"], actor: admin)

      assert file_object.resource_id == nil
      assert file_object.referenced_at == nil
    end

    test "a host that refuses the object fails the entry rather than signing a URL" do
      # The same key twice in one presign is fine — custody upserts — so the
      # refusal is provoked with a key the row cannot hold: `:source` is
      # constrained to `:upload_form`.
      entry = entry(uuid: "refused-1", client_name: "photo.jpg")

      assert {:error, %{error: "upload_refused"}, _socket} =
               FormUtils.presign_attachment_upload(
                 entry,
                 socket(),
                 Keyword.put(@image_field, :visibility, :public)
                 |> Keyword.put(:accepts, [:nonsense])
               )
    end
  end

  describe "safe_filename/1 (the traversal guard)" do
    test "strips directory components and `..` segments" do
      # `Path.basename` keeps only the final segment, so directory components
      # (including any `..`) never survive into the key.
      assert FormUtils.safe_filename("../../public/evil.html") == "evil.html"
      assert FormUtils.safe_filename("/etc/passwd") == "passwd"
      assert FormUtils.safe_filename("a/b/c.png") == "c.png"
    end

    test "slugifies unsafe characters and lowercases" do
      assert FormUtils.safe_filename("My Vacation Photo (1).JPG") == "my-vacation-photo-1.jpg"
    end

    test "falls back to a generic name for empty/non-binary input" do
      assert FormUtils.safe_filename("الصورة.png") == "file.png"
      assert FormUtils.safe_filename(nil) == "file"
    end
  end

  defp socket(assigns \\ []) do
    %{assigns: assigns |> Keyword.put_new(:resource, Example.Catalog.Product) |> Map.new()}
  end

  defp entry(overrides) do
    %{uuid: "abc", client_name: "photo.jpg", client_type: "image/jpeg", client_size: 1_024}
    |> Map.merge(Map.new(overrides))
  end
end
