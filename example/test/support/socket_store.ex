defmodule Example.Test.SocketStore do
  @moduledoc """
  A storage module with no `upload_target/2`, so browser uploads come over the
  LiveView socket and are stored with `put_file/3` (`AshQuick.Storage`,
  "Browser uploads").

  It keeps objects on local disk under `root/0`. A key holding `refuse` is
  refused, so a test can show what a person is told when the store says no.
  Only `ExampleWeb.SocketUploadScenarioTest` points `:storage` here, and it runs
  synchronously because the setting is global.
  """
  @behaviour AshQuick.Storage

  @doc "Where the objects are written."
  def root, do: Path.join(System.tmp_dir!(), "ash_quick_socket_store")

  @doc "The bytes stored at `key`, or `nil`."
  def read(key) do
    case File.read(Path.join(root(), key)) do
      {:ok, bytes} -> bytes
      {:error, _reason} -> nil
    end
  end

  @impl true
  def url(key, _opts), do: "/socket-store/" <> key

  @impl true
  def download_url(key, opts), do: "/socket-store/#{key}?filename=#{opts[:filename]}"

  @impl true
  def put_file(key, path, _opts) do
    if key =~ "refuse" do
      {:error, :refused}
    else
      destination = Path.join(root(), key)
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(path, destination)
    end
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
