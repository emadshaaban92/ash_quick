defmodule AshQuick.LiveView.AttachmentUpload do
  @moduledoc ~S"""
  Signing, naming and checking one attachment upload: what a custom upload
  widget calls to take part in an AshQuick form the way the built-in inputs
  do.

  An `AshQuick.AshTypes.Attachment` field's form allows an upload named
  `"#{phx_field.name}_upload"` and does the rest itself. A widget that allows
  its own upload, or signs its own entries, builds it from these:

    * `presign_attachment_upload/3` is the `:external` function for
      `Phoenix.LiveView.allow_upload/3` when the storage module takes uploads
      in the browser. It refuses a name the field does not accept, takes
      custody of the object, and records its key as one the page minted, so
      the form takes it back from a post.
    * `upload_error_message/1` words any error
      `Phoenix.Component.upload_errors/2` returns.
    * `safe_filename/1` is the slug every key built from a browser-supplied
      name must go through.

  The constraints each takes are the field's own: an attachment field's
  `constraints`, or an array field's `:items`.
  """
  require Logger
  use Gettext, backend: AshQuick.Gettext
  alias AshQuick.LiveView.AttachmentKeys
  alias AshQuick.LiveView.Utils
  alias AshQuick.Storage

  @doc false
  def attachment_constraints(%{type: AshQuick.AshTypes.Attachment, constraints: c}), do: c || []

  def attachment_constraints(%{type: {:array, AshQuick.AshTypes.Attachment}, constraints: c}) do
    (c || []) |> Keyword.get(:items, [])
  end

  @default_max_size_mb 50

  @doc false
  def attachment_max_bytes(constraints),
    do: Keyword.get(constraints, :max_size_mb, @default_max_size_mb) * 1024 * 1024

  # The extensions each media class takes, with the type every surface stores
  # and serves the object as. The type comes from here, not from the browser:
  # what an entry declares is whatever the picker was told, and a name ending
  # `.html` declared `image/jpeg` is still an HTML page to anything that serves
  # it by its key.
  @attachment_media_types %{
    image: [
      {".jpg", "image/jpeg"},
      {".jpeg", "image/jpeg"},
      {".png", "image/png"},
      {".webp", "image/webp"}
    ],
    video: [{".mp4", "video/mp4"}, {".mov", "video/quicktime"}, {".webm", "video/webm"}],
    document: [{".pdf", "application/pdf"}]
  }

  defp attachment_media_types(accepts) do
    Enum.flat_map(accepts, &Map.get(@attachment_media_types, &1, []))
  end

  @doc false
  def attachment_accept_extensions(accepts) do
    accepts |> attachment_media_types() |> Enum.map(&elem(&1, 0))
  end

  # `allow_upload/3`'s `accept:` is not enough on its own: LiveView passes an
  # entry when its declared type *or* its name matches, and both are the
  # browser's to say. The name is what the key is built from, so the name is
  # what is checked. LiveView runs this on the server for every entry, before
  # it is presigned and before any of its bytes are sent over the socket.
  @doc false
  def validate_attachment_entry(entry, constraints) do
    if accepted_media_type(entry, constraints), do: :ok, else: {:error, :not_accepted}
  end

  # The media type for an entry whose name the field accepts, or `nil`.
  @doc false
  def accepted_media_type(entry, constraints) do
    ext = entry.client_name |> safe_filename() |> Path.extname()

    constraints
    |> Keyword.get(:accepts, [])
    |> attachment_media_types()
    |> List.keyfind(ext, 0, {ext, nil})
    |> elem(1)
  end

  @doc """
  Names where the browser writes one upload entry: the storage module's
  `c:AshQuick.Storage.upload_target/2`, asked for the write key. Only called
  when the storage module takes uploads externally.

  The key the record will store is the **serving** key, built from the
  field's `:visibility`. Where the bytes actually go is
  `AshQuick.Storage.object_arriving/2`'s call — a host that holds objects somewhere
  first hands back a different key, and the target is asked for that one.
  The form's save rebuilds the serving key from the same entry, so the
  record never learns where the bytes waited.

  Both keys go back to the browser: `key` is where to write, `serving_key`
  is the name every surface will render the object under. A client that
  wants to say something about an object it just picked —
  `AshQuick.Components.attachment_img/1` marks its placeholder with the
  serving key — has it stated rather than having to derive it from where the
  bytes happen to be waiting.

  Custody is taken here, at presign, rather than at submit: `auto_upload:
  true` means the bytes land as soon as a file is picked, so an object the
  host was told about only on save would be one it never heard of for every
  form that is abandoned.

  The serving key is also recorded on the socket as one this page minted,
  for the top-level field the entry's upload is named after
  (`"form[field]_upload"`, or a sub-form's upload under that field). The
  library's own save and progress paths record it again, for the same field,
  when they consume the entry; the record made here is what binds it before
  then (a post that names it ahead of the save) and for a host that consumes
  the entry itself.

  A form takes back only attachment keys it issued, and a minted key counts
  in the field it was uploaded for and in no other field the action takes as
  input, since the upload checked the file against that field's types and
  size. A field the action does not take (one a change folds the upload
  onto) holds it wherever it was uploaded, so a change that builds an
  attachment from an argument that is not an attachment (a string, a map)
  makes that field trust any key the page minted. The binding is per
  top-level field: under a sub-form, a key can still move between attachment
  fields under the same top-level field (a row's scan into a row's photo). A
  host that signs its own uploads without this function, or under an upload
  not named after a form field, has its keys dropped from the post.

  The field's `:accepts` and `:max_size_mb` go with it because they cannot
  be recovered later — a key alone does not say which Ash type constraint
  produced it.

  An entry whose name does not end in one of the field's extensions never
  gets here from a form: the upload's `:validator` refuses it first. Called
  with one anyway, it is refused before any key is opened or signed.

  The target is told the type the name's extension stands for and the
  entry's declared size (`:content_type`, `:content_length`), never the
  browser's declared type. `max_file_size` on `allow_upload/3` only bounds
  what the browser offers at preflight, so a target that does not bind the
  length lets anyone holding it store an object of any size, and one that
  does not bind the type lets them store it as any type.
  """
  def presign_attachment_upload(entry, socket, constraints) do
    case accepted_media_type(entry, constraints) do
      nil -> {:error, %{error: "not_accepted"}, socket}
      media_type -> presign_accepted_upload(entry, socket, constraints, media_type)
    end
  end

  defp presign_accepted_upload(entry, socket, constraints, media_type) do
    serving_key = build_attachment_key(entry, socket, Keyword.fetch!(constraints, :visibility))

    case Storage.object_arriving(
           serving_key,
           arriving_opts(entry, socket, constraints, media_type)
         ) do
      {:ok, write_key} ->
        {:external, uploader, meta} =
          Storage.upload_target(write_key,
            content_type: media_type,
            content_length: entry.client_size
          )

        # Recorded here, where the key is made, rather than where an entry is
        # consumed: a form takes back only keys it issued, and every upload —
        # on the root form or a sub-form, consumed on progress or at save —
        # passes through this one place.
        meta = Map.merge(meta, %{uploader: uploader, key: write_key, serving_key: serving_key})

        {:ok, meta,
         AttachmentKeys.mint_attachment_key(socket, serving_key, Map.get(entry, :upload_config))}

      # The host refused to take the object. Nothing has been written yet, so
      # failing the entry is the honest outcome — the browser shows the error
      # and the form has no key to save.
      {:error, reason} ->
        Logger.error(
          "upload of #{serving_key} refused by the object lifecycle: #{inspect(reason)}"
        )

        {:error, %{error: "upload_refused"}, socket}
    end
  end

  @doc """
  Renders an upload entry's error for the surface the file was picked on.

  Every error `Phoenix.Component.upload_errors/2` can return has to land
  somewhere: a picker that only knows the built-in atoms crashes the render
  the first time the presigner refuses an entry, which is a live page lost to
  an error the user was supposed to just read.
  """
  def upload_error_message(:too_large), do: gettext("Too large")
  def upload_error_message(:too_many_files), do: gettext("You have selected too many files")

  def upload_error_message(:not_accepted),
    do: gettext("You have selected an unacceptable file type")

  def upload_error_message(:external_client_failure), do: gettext("External Client Failure")

  # The presigner refused the entry, so no URL was signed and no bytes left the
  # browser. Nothing retries it — say the file was not uploaded.
  def upload_error_message({:external_metadata_failure, _meta}),
    do: gettext("This file was refused and has not been uploaded")

  # A socket upload arrived but the store refused it: the file is not saved.
  def upload_error_message(:not_stored),
    do: gettext("This file was refused and has not been uploaded")

  def upload_error_message(error) when is_atom(error), do: Utils.humanize(error)
  def upload_error_message(_error), do: gettext("This file could not be uploaded")

  @doc false
  def arriving_opts(entry, socket, constraints, media_type) do
    [
      source: :upload_form,
      accepts: Keyword.get(constraints, :accepts),
      max_bytes: attachment_max_bytes(constraints),
      content_type: media_type,
      byte_size: entry.client_size,
      filename: entry.client_name,
      resource: socket.assigns.resource,
      # A create form has no record yet, which is why the link to what an
      # object belongs to is stamped at save instead.
      resource_id: socket.assigns |> Map.get(:record) |> record_id(),
      scope: Map.get(socket.assigns, :scope)
    ]
  end

  defp record_id(%{id: id}), do: id
  defp record_id(_record), do: nil

  @doc false
  def build_attachment_key(entry, socket, visibility) do
    directory = Ash.Resource.Info.plural_name(socket.assigns.resource)
    "#{visibility}/#{directory}/#{entry.uuid}-#{safe_filename(entry.client_name)}"
  end

  @doc """
  Slugifies a browser-supplied filename into a storage-key-safe segment.

  The human-readable filename in a key is cosmetic — a UUID guarantees
  uniqueness and `original_filename` preserves the real name for display.
  Slugifying keeps URL-unsafe characters (spaces, parens, `#`, unicode, ...)
  out of the storage key, and therefore out of the URL. Both the base name
  and the extension are slugged — the extension keeps only `[a-z0-9]` so
  something like `report.jp g` or `x.htm<b>l` can't smuggle spaces, control
  bytes, or markup into the key.

  Crucially it is also the traversal guard: `Path.basename/2` strips any
  directory components and the `[^a-z0-9]+` collapse destroys `.` and `/`,
  so a `client_name` like `../../public/evil.html` can never escape its
  intended prefix. Every presigned-upload key builder that interpolates a
  browser-controlled name MUST route it through this function.
  """
  def safe_filename(name) when is_binary(name) do
    ext = name |> Path.extname() |> slug_extension()

    base =
      name
      |> Path.basename(Path.extname(name))
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    case base do
      "" -> "file" <> ext
      base -> base <> ext
    end
  end

  def safe_filename(_), do: "file"

  # Slugs a `.ext` down to its leading dot plus `[a-z0-9]` only, dropping the
  # extension entirely when nothing survives (so `x/..` -> "file", not "file.").
  defp slug_extension("." <> rest) do
    case rest |> String.downcase() |> String.replace(~r/[^a-z0-9]+/u, "") do
      "" -> ""
      cleaned -> "." <> cleaned
    end
  end

  defp slug_extension(_), do: ""

  @doc false
  def infer_attachment_file_type(filename) when is_binary(filename) do
    ext = filename |> safe_filename() |> Path.extname()

    Enum.find_value(@attachment_media_types, fn {class, types} ->
      if List.keymember?(types, ext, 0), do: class
    end)
  end

  def infer_attachment_file_type(_), do: nil
end
