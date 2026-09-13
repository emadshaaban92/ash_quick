defmodule AshQuick.AshTypes.Attachment do
  @moduledoc """
  An Ash type for uploaded files (images and videos), stored as an
  object-storage `key` plus media-class metadata.

  Per-field policy is expressed as Ash type constraints and read by the
  AshQuick upload pipeline:

    * `:visibility` (`:public` | `:private`, required) — selects the key
      prefix (`public/...` or `private/...`) which the bucket policy uses
      to grant or deny anonymous access. See `AshQuick.Storage` for the
      bucket policy contract the host application is expected to
      provide.
    * `:accepts` (list of `:image` and/or `:video`, required) — allowed
      media classes for this field.
    * `:max_size_mb` (positive integer, default 50) — hard per-file size
      cap.

  The runtime value is `AshQuick.AshTypes.Attachment.Value`. Fields can
  hold a single attachment or `{:array, :attachment}` for multiple.

  ## Wrapping in an embed for per-record metadata

  The value struct carries only storage-relevant fields. For per-record
  display metadata (alt text, featured flag, captions, ...), wrap this
  type in an embedded resource and put the metadata there:

      defmodule MyApp.ProductImage do
        use Ash.Resource, data_layer: :embedded

        attributes do
          attribute :attachment, AshQuick.AshTypes.Attachment,
            allow_nil?: false,
            public?: true,
            constraints: [visibility: :public, accepts: [:image], max_size_mb: 10]

          attribute :alt, :string, public?: true
          attribute :featured, :boolean, default: false, public?: true
        end
      end

  `AshQuick.LiveView.FormUtils` handles two wiring shapes:

    1. A field typed `:attachment` directly (or `{:array, :attachment}`)
       — constraints are read from the field itself
       (e.g. `ReturnRequest.attachments`).
    2. A field typed as an embedded resource (or array of embeds) that
       has an `:attachment` attribute — the upload is wired through the
       embed's nested form, reading constraints from the wrapped
       attribute (e.g. `Product.images`, `Category.image`).

  The convention: when a resource has nothing per-attachment beyond
  storage, use `:attachment` directly; when it needs richer metadata,
  wrap it in an embed.

  ## Notes

    * `:accepts` is a media class, not a format. The extensions a class
      offers are listed in `AshQuick.LiveView.FormUtils`, and `:image`
      deliberately excludes HEIC: browsers don't render it uniformly
      and AshQuick does not transcode.
    * Gating here is extension-based, which a rename defeats. Content
      validation belongs to the host, behind
      `AshQuick.Storage`'s lifecycle callbacks — AshQuick hands it the bytes' destined
      key and serves only what it calls `:ready`.
  """

  use Ash.Type

  alias AshQuick.AshTypes.Attachment.Value

  @impl Ash.Type
  def storage_type(_), do: :map

  @impl Ash.Type
  def constraints do
    [
      visibility: [
        type: {:in, [:public, :private]},
        required: true,
        doc: """
        :public  — uploaded under `public/...`. Readable by anyone via the
                   bucket policy; rendered as a deterministic HTTPS URL.
        :private — uploaded under `private/...`. Bucket policy does not
                   grant anonymous access; rendered as a short-lived
                   presigned GET URL.
        """
      ],
      accepts: [
        type: {:list, {:in, [:image, :video]}},
        required: true,
        doc: "Allowed media classes for this attachment field. At least one."
      ],
      max_size_mb: [
        type: :pos_integer,
        default: 50,
        doc: "Hard limit per uploaded file in megabytes. Defaults to 50."
      ]
    ]
  end

  @impl Ash.Type
  def cast_input(nil, _constraints), do: {:ok, nil}
  def cast_input("", _constraints), do: {:ok, nil}
  def cast_input(%Value{} = value, _constraints), do: {:ok, value}

  def cast_input(map, _constraints) when is_map(map) do
    to_value(map)
  end

  def cast_input(json, constraints) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> cast_input(map, constraints)
      _ -> :error
    end
  end

  def cast_input(_, _constraints), do: :error

  @impl Ash.Type
  def cast_stored(nil, _constraints), do: {:ok, nil}
  def cast_stored(%Value{} = value, _constraints), do: {:ok, value}

  def cast_stored(map, _constraints) when is_map(map) do
    to_value(map)
  end

  def cast_stored(_, _constraints), do: :error

  @impl Ash.Type
  def dump_to_native(nil, _constraints), do: {:ok, nil}

  def dump_to_native(%Value{} = value, _constraints) do
    {:ok, Map.from_struct(value)}
  end

  def dump_to_native(_, _constraints), do: :error

  @impl Ash.Type
  def apply_constraints(nil, _constraints), do: {:ok, nil}

  def apply_constraints(%Value{} = value, constraints) do
    visibility = Keyword.fetch!(constraints, :visibility)
    accepts = Keyword.fetch!(constraints, :accepts)

    []
    |> validate_key_prefix(value, visibility)
    |> validate_file_type(value, accepts)
    |> case do
      [] -> {:ok, value}
      errors -> {:error, errors}
    end
  end

  defp validate_key_prefix(errors, %Value{key: key}, visibility) do
    expected_prefix = "#{visibility}/"

    if is_binary(key) and String.starts_with?(key, expected_prefix) do
      errors
    else
      [[field: :key, message: "must start with `#{expected_prefix}`"] | errors]
    end
  end

  defp validate_file_type(errors, %Value{file_type: nil}, _accepts), do: errors

  defp validate_file_type(errors, %Value{file_type: file_type}, accepts) do
    if file_type in accepts do
      errors
    else
      [
        [
          field: :file_type,
          message: "`#{inspect(file_type)}` is not in accepted classes #{inspect(accepts)}"
        ]
        | errors
      ]
    end
  end

  defp to_value(map) do
    key = Map.get(map, :key) || Map.get(map, "key")

    if is_binary(key) and key != "" do
      {:ok,
       %Value{
         key: key,
         file_type: cast_file_type(Map.get(map, :file_type) || Map.get(map, "file_type")),
         original_filename: Map.get(map, :original_filename) || Map.get(map, "original_filename"),
         byte_size: cast_byte_size(Map.get(map, :byte_size) || Map.get(map, "byte_size"))
       }}
    else
      :error
    end
  end

  defp cast_file_type(nil), do: nil
  defp cast_file_type(:image), do: :image
  defp cast_file_type(:video), do: :video
  defp cast_file_type("image"), do: :image
  defp cast_file_type("video"), do: :video
  defp cast_file_type(_), do: nil

  defp cast_byte_size(nil), do: nil
  defp cast_byte_size(n) when is_integer(n) and n >= 0, do: n
  defp cast_byte_size(_), do: nil
end
