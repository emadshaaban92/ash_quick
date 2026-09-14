defmodule Example.Uploads.ObjectStore do
  @moduledoc """
  What `config :ash_quick, storage:` points at.

  Two halves, which is what makes it worth reading as an example.

  The **bucket** half names a bucket of its own rather than
  `AshQuick.Config.s3_bucket/0`, and signs through `AshQuick.Storage.S3`. That
  is the shape of a host that already owns an object-store client: AshQuick
  states the signing and key encoding once, and holds no second opinion about
  which bucket the object is in.

  The **lifecycle** half implements all three optional callbacks. An arriving
  object is recorded as an `Example.Uploads.FileObject` and its bytes are
  routed to `Example.Uploads.Quarantine`, so nothing is servable until
  `release!/1` says so. `AshQuick.Storage.S3` implements none of the three and
  is the other side of that comparison — the passthrough, where the bytes go
  to the key they were destined for and every object is servable.

  Custody is taken at presign rather than at save because uploads are
  `auto_upload: true`: the bytes are in storage the moment a file is picked.
  `object_referenced/3` is the only signal that anything ever came back for
  them.
  """

  @behaviour AshQuick.Storage

  require Logger

  alias Example.Uploads.FileObject
  alias Example.Uploads.Quarantine

  @doc "The one bucket every upload surface in this app names."
  def bucket, do: "ash-quick-example-uploads"

  @doc "The host public URLs are built against."
  def host, do: "uploads.example.invalid"

  @impl true
  def public_url(key), do: AshQuick.Storage.S3.public_url(bucket(), host(), key)

  @impl true
  def presigned_put_url(key, opts), do: AshQuick.Storage.S3.presigned_put_url(bucket(), key, opts)

  @impl true
  def presigned_get_url(key, opts), do: AshQuick.Storage.S3.presigned_get_url(bucket(), key, opts)

  @impl true
  def upload(key, path, opts), do: AshQuick.Storage.S3.upload(bucket(), key, path, opts)

  @impl true
  def object_arriving(serving_key, opts) do
    attributes = %{
      key: serving_key,
      source: Keyword.get(opts, :source, :upload_form),
      accepts: Keyword.get(opts, :accepts),
      max_bytes: Keyword.get(opts, :max_bytes),
      content_type: Keyword.get(opts, :content_type),
      byte_size: Keyword.get(opts, :byte_size),
      original_filename: Keyword.get(opts, :filename),
      resource_name: short_name(Keyword.get(opts, :resource)),
      resource_id: Keyword.get(opts, :resource_id),
      actor_id: actor_id(opts)
    }

    case FileObject.take_custody(attributes, actor: actor(opts), authorize?: false) do
      {:ok, _file_object} ->
        {:ok, Quarantine.key(serving_key)}

      # Nothing has been written yet, so refusing is honest: the browser shows
      # the error and the form has no key to save.
      {:error, error} ->
        Logger.error("""
        failed to take custody of #{serving_key}, refusing the upload:
        #{Exception.message(error)}
        """)

        {:error, error}
    end
  end

  @impl true
  def object_states(keys) do
    case FileObject.by_keys(keys, authorize?: false) do
      {:ok, file_objects} -> Map.new(file_objects, &{&1.key, &1.state})
      {:error, _error} -> %{}
    end
  end

  @impl true
  def object_referenced(keys, resource, resource_id) do
    with {:ok, file_objects} <- FileObject.by_keys(keys, authorize?: false) do
      Enum.reduce_while(file_objects, :ok, fn file_object, :ok ->
        file_object
        |> FileObject.reference(
          %{resource_name: short_name(resource), resource_id: resource_id},
          authorize?: false
        )
        |> case do
          {:ok, _referenced} -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  @doc """
  Releases `serving_key`, as the host's own pipeline would once whatever it was
  holding the object for finished. Nothing in this app runs on a schedule; the
  demo seeds call it directly.
  """
  def release!(serving_key) do
    [serving_key]
    |> FileObject.by_keys!(authorize?: false)
    |> Enum.each(&FileObject.release!(&1, authorize?: false))

    :ok
  end

  defp short_name(nil), do: nil
  defp short_name(resource), do: Ash.Resource.Info.short_name(resource)

  defp actor(opts), do: opts |> Keyword.get(:scope) |> AshQuick.Scope.actor()

  defp actor_id(opts) do
    case actor(opts) do
      %{id: id} -> id
      _no_actor -> nil
    end
  end
end
