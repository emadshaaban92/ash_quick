defmodule Example.Test.SocketStore do
  @moduledoc """
  `use AshQuick.Storage.Local`, which has no `upload_target/2`, so browser uploads
  come over the LiveView socket and are stored with `put_file/3`
  (`AshQuick.Storage`, "Browser uploads").

  A key holding `refuse` is refused, so a test can show what a person is told
  when the store says no. Only `ExampleWeb.SocketUploadScenarioTest` points
  `:storage` here, and it runs synchronously because the setting is global.
  """
  use AshQuick.Storage.Local

  alias AshQuick.Storage.Local

  @doc "Where the objects are written: `AshQuick.Storage.Local`'s `:root`."
  def root, do: Application.fetch_env!(:ash_quick, Local)[:root]

  @doc "The bytes stored at `key`, or `nil`."
  def read(key) do
    with {:ok, path} <- Local.file_path(key),
         {:ok, bytes} <- File.read(path) do
      bytes
    else
      {:error, _reason} -> nil
    end
  end

  @impl true
  def put_file(key, path, opts) do
    if key =~ "refuse",
      do: {:error, :refused},
      else: Local.put_file(key, path, opts)
  end
end

defmodule Example.Test.PathMetaStore do
  @moduledoc """
  An external-upload store whose upload target's meta names a `path`, as a
  host's own meta may (an object path on GCS or Azure, say). AshQuick must
  still read the entry as external, and not hand `put_file/3` a file that
  does not exist.
  """
  @behaviour AshQuick.Storage

  alias Example.Uploads.ObjectStore

  @impl true
  def url(key, opts), do: ObjectStore.url(key, opts)

  @impl true
  def download_url(key, opts), do: ObjectStore.download_url(key, opts)

  @impl true
  def put_file(key, _path, _opts), do: {:error, {:unexpected_put_file, key}}

  @impl true
  def upload_target(key, opts) do
    {:external, uploader, meta} = ObjectStore.upload_target(key, opts)
    {:external, uploader, Map.put(meta, :path, "bucket/" <> key)}
  end
end
