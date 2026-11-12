defmodule AshQuick.Storage.Local do
  @moduledoc """
  An `AshQuick.Storage` that keeps objects on the server's own disk.

  It suits an application that runs on one node, or on several that share a
  volume, and that backs that directory up itself. Nothing leaves the
  application's origin: browser uploads come over the LiveView socket, and
  objects are read back through `AshQuick.Storage.Local.Plug`, so there is no
  bucket policy, no CORS and nothing to add to a Content Security Policy.

  ## Setting it up

      config :ash_quick, storage: AshQuick.Storage.Local

      config :ash_quick, AshQuick.Storage.Local,
        root: "/var/lib/my_app/uploads",
        endpoint: MyAppWeb.Endpoint

  and, in the router, outside any pipeline:

      forward "/ash_quick/files", AshQuick.Storage.Local.Plug

  Options, read when they are used, so `config/runtime.exs` can set them:

    * `:root` — the directory objects are written under. Required. A key's
      `/`-separated segments become directories below it.
    * `:endpoint` — the Phoenix endpoint whose `secret_key_base` signs the
      links handed out for private objects. Required unless
      `:secret_key_base` is given.
    * `:secret_key_base` — the key to sign with instead of an endpoint's.
    * `:at` — the path the plug is forwarded at, which every URL is built
      from. Defaults to `"/ash_quick/files"`. Inside a router `scope`, it is
      the full path the scope puts the forward at. `mix ash_quick.check`
      reports a router that does not forward it.

  Set them in configuration: links are built from it, and the plug and
  `mix ash_quick.check` read it too, so a `:root` or a secret given only on
  the router's forward leaves every link pointing at a file the plug cannot
  find or a token it cannot verify. Each callback and the plug do take them in
  their opts as well, over the configured ones.

  ## Adding to it

  A host that wants the lifecycle callbacks (`c:AshQuick.Storage.object_arriving/2`
  and the rest) on disk storage writes a module of its own and points
  `:storage` at that:

      defmodule MyApp.Uploads.Store do
        use AshQuick.Storage.Local

        @impl true
        def object_arriving(serving_key, opts), do: ...
      end

  `use` delegates `url/2`, `download_url/2` and `put_file/3` here, each of
  them overridable, and marks the module as backed by this one, so
  `mix ash_quick.check` still holds the router to the forward.

  ## What a URL grants

  A `public/*` object is served to anyone who asks for its path, as a bucket
  policy would serve it. Every other object needs the token on its link: a
  `Phoenix.Token` naming the key, signed with the endpoint's secret and good
  for `:expires_in` seconds. Like a presigned URL, the link is a bearer
  capability until it expires, handed out only to a page that was allowed to
  render the object. A link with no token, a tampered or expired one, or one
  minted for another key answers `404`.

  A download link's token also carries the filename, so the browser saves the
  object under it rather than showing it.

  ## Serving uploads from the application's origin

  An uploaded file is served from the same origin as the pages, so a file a
  browser would run (HTML, SVG, XML) must not be shown as one. Every response
  carries `x-content-type-options: nosniff` and a sandboxing
  `content-security-policy`, and only images (other than SVG), audio, video,
  PDFs and plain text are shown inline. Anything else is sent as an
  attachment. The media type is read off the key's extension.

  ## Keys

  A key is written below `:root` exactly as it is named. One that could reach
  outside it is refused, by `put_file/3` and by the plug alike: an absolute
  key, an empty segment, `.` or `..`, a backslash or a NUL byte. So is a key
  with a `:`, which `Plug.Static` will not serve; refusing it on write keeps
  `put_file/3` from storing what could never be read back.

  ## What is deleted

  Exports are: `AshQuick.Storage.Sweeper`, which runs under `AshQuick` in the
  host's supervision tree, removes every file under `exports/` older than
  `:export_retention` (a day by default) through `delete_expired/3`.

  Nothing else is. An attachment a record no longer holds stays at its key.
  """
  @behaviour AshQuick.Storage

  alias AshQuick.Storage.Served

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour AshQuick.Storage

      @doc false
      def __ash_quick_local__, do: true

      @impl AshQuick.Storage
      def url(key, opts), do: AshQuick.Storage.Local.url(key, opts)

      @impl AshQuick.Storage
      def download_url(key, opts), do: AshQuick.Storage.Local.download_url(key, opts)

      @impl AshQuick.Storage
      def put_file(key, path, opts), do: AshQuick.Storage.Local.put_file(key, path, opts)

      @impl AshQuick.Storage
      def delete_expired(prefix, max_age, opts),
        do: AshQuick.Storage.Local.delete_expired(prefix, max_age, opts)

      defoverridable url: 2, download_url: 2, put_file: 3, delete_expired: 3
    end
  end

  @doc """
  Whether `storage` keeps its objects through this module: it is this module,
  or it was written with `use AshQuick.Storage.Local`.
  """
  @spec backs?(module()) :: boolean()
  def backs?(__MODULE__), do: true

  def backs?(storage) when is_atom(storage),
    do: Code.ensure_loaded?(storage) and function_exported?(storage, :__ash_quick_local__, 0)

  def backs?(_storage), do: false

  @impl true
  def url(key, opts), do: Served.url(__MODULE__, key, opts)

  @impl true
  def download_url(key, opts), do: Served.download_url(__MODULE__, key, opts)

  @doc """
  Writes the file at `path` to `key` below `:root`.

  The bytes go to a temporary file beside the destination first and are moved
  into place, so a reader never sees half an object. The media type is read
  off the key when the object is served, so `:content_type` is not stored.
  """
  # The destination comes from `file_path/2`, which refuses any key that could
  # reach outside `:root`; `path` is a file AshQuick itself holds.
  @impl true
  # sobelow_skip ["Traversal.FileModule"]
  def put_file(key, path, opts) do
    with {:ok, destination} <- file_path(key, opts),
         :ok <- File.mkdir_p(Path.dirname(destination)) do
      partial =
        destination <> ".partial-" <> Integer.to_string(System.unique_integer([:positive]))

      with :ok <- File.cp(path, partial),
           :ok <- File.rename(partial, destination) do
        :ok
      else
        {:error, _reason} = error ->
          File.rm(partial)
          error
      end
    end
  end

  @doc """
  Deletes every file below `prefix` last written more than `max_age` seconds
  ago, and answers how many went. Directories are left in place.

  A `prefix` nothing was ever written under is not an error: there is nothing
  to delete.
  """
  @impl true
  def delete_expired(prefix, max_age, opts)
      when is_integer(max_age) and max_age > 0 do
    with {:ok, directory} <- file_path(prefix, opts) do
      cutoff = System.os_time(:second) - max_age
      {:ok, directory |> files_below() |> Enum.count(&delete_if_older(&1, cutoff))}
    end
  end

  defp files_below(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(path) do
          {:ok, names} -> Enum.flat_map(names, &files_below(Path.join(path, &1)))
          {:error, _reason} -> []
        end

      {:ok, %File.Stat{type: :regular}} ->
        [path]

      # A link is not followed: what it points at may be outside `:root`.
      _other ->
        []
    end
  end

  # Only a path `files_below/1` found under `file_path/2`'s answer, which is
  # inside `:root`, and never through a link.
  # sobelow_skip ["Traversal.FileModule"]
  defp delete_if_older(path, cutoff) do
    with {:ok, %File.Stat{mtime: written}} when written < cutoff <-
           File.lstat(path, time: :posix),
         :ok <- File.rm(path) do
      true
    else
      _kept -> false
    end
  end

  @doc """
  The file `key` is stored at, or `{:error, :invalid_key}` for a key that could
  reach outside `:root`. See "Keys" above.
  """
  @spec file_path(AshQuick.Storage.key(), keyword()) :: {:ok, Path.t()} | {:error, :invalid_key}
  def file_path(key, opts \\ []) do
    if safe_key?(key),
      do: {:ok, Path.join(root(opts), key)},
      else: {:error, :invalid_key}
  end

  @doc false
  # `AshQuick.Storage.Served.safe_key?/1`, and no `:`, because `Plug.Static`
  # refuses it (a drive letter on Windows), so it could be written and never
  # read.
  def safe_key?(key),
    do: Served.safe_key?(key) and not String.contains?(key, ":")

  @doc false
  def verify(key, token, opts), do: Served.verify(__MODULE__, key, token, opts)

  @doc false
  def option(opts, name, default \\ nil), do: Served.option(__MODULE__, opts, name, default)

  @doc false
  # The path the plug is forwarded at, without a trailing slash.
  def at(opts), do: Served.at(__MODULE__, opts)

  @doc false
  def root(opts) do
    case option(opts, :root) do
      root when is_binary(root) and root != "" ->
        root

      _missing ->
        raise ArgumentError,
              "AshQuick.Storage.Local needs a :root, the directory objects are written under: " <>
                "config :ash_quick, AshQuick.Storage.Local, root: \"/var/lib/my_app/uploads\""
    end
  end

  defmodule Plug do
    @moduledoc """
    Serves the objects `AshQuick.Storage.Local` stores.

    Forward to it at the storage's `:at` path, outside any pipeline: what
    opens an object is the link's token, not the session, and a pipeline that
    checks the `accept` header or a CSRF token gets in an image's way.

        forward "/ash_quick/files", AshQuick.Storage.Local.Plug

    Answers `GET` and `HEAD`. Range requests, `etag`s and `304`s come from
    `Plug.Static`, which sends the file once the link has been checked.
    Options given to the forward are read over the configured ones, but the
    links are built from configuration alone, so set `:root` and the signing
    secret there (see "Setting it up" in `AshQuick.Storage.Local`).
    """
    @behaviour Elixir.Plug

    alias AshQuick.Storage.Local
    alias AshQuick.Storage.Served

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%Elixir.Plug.Conn{method: method} = conn, opts) when method in ["GET", "HEAD"] do
      with {:ok, key} <- Served.request_key(conn),
           true <- Local.safe_key?(key),
           {:ok, filename} <- Served.grant(Local, conn, key, opts) do
        serve(conn, key, filename, opts)
      else
        _refused -> Served.not_found(conn)
      end
    end

    def call(conn, _opts), do: Served.not_found(conn)

    defp serve(conn, key, filename, opts) do
      static =
        Elixir.Plug.Static.init(
          at: "/",
          from: Local.root(opts),
          cache_control_for_etags: Served.cache_control(key),
          gzip: false,
          brotli: false
        )

      # `Plug.Static` decodes each segment again, so it is handed them encoded:
      # a key naming `100%.png` is the file `100%.png`, not a decoding error.
      served =
        conn
        |> Served.put_object_headers(key, filename)
        |> Map.put(:path_info, key |> String.split("/") |> Enum.map(&encode_segment/1))
        |> Elixir.Plug.Static.call(static)

      if served.halted, do: served, else: Served.not_found(conn)
    end

    defp encode_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
  end
end
