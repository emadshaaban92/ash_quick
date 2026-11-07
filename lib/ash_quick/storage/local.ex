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

  ## Files are never deleted

  Nothing here removes a file: an export stays under `exports/<actor id>/`,
  and an attachment a record no longer holds stays at its key. A full disk
  stops the application, so clear `exports/` on a schedule of your own.
  """
  @behaviour AshQuick.Storage

  @default_ttl_seconds 3600
  @default_at "/ash_quick/files"
  @salt "ash_quick storage"

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

      defoverridable url: 2, download_url: 2, put_file: 3
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
  def url(key, opts) do
    case Keyword.get(opts, :visibility, :private) do
      :public -> path(key, opts)
      :private -> signed(key, nil, opts)
    end
  end

  @impl true
  def download_url(key, opts), do: signed(key, Keyword.fetch!(opts, :filename), opts)

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
  # A `:` is refused because `Plug.Static` refuses it (a drive letter on
  # Windows), so it could be written and never read.
  #
  # Anchored by segment, so a name that merely contains dots (`a..b.jpg`) is
  # fine while `..` on its own is not. `Path.safe_relative/1` would accept
  # `a/../b` by collapsing it into another key.
  def safe_key?(key) when is_binary(key) and key != "" do
    String.valid?(key) and not String.contains?(key, ["\\", ":", <<0>>]) and
      key |> String.split("/") |> Enum.all?(&(&1 not in ["", ".", ".."]))
  end

  def safe_key?(_key), do: false

  @doc false
  # What a token names, or `:error`. A token minted for another key does not
  # open this one.
  def verify(key, token, opts) do
    case Phoenix.Token.verify(signer(opts), @salt, token) do
      {:ok, %{"k" => ^key} = claims} -> {:ok, Map.get(claims, "f")}
      _invalid -> :error
    end
  end

  @doc false
  def option(opts, name, default \\ nil) do
    Keyword.get_lazy(opts, name, fn ->
      :ash_quick |> Application.get_env(__MODULE__, []) |> Keyword.get(name, default)
    end)
  end

  defp signed(key, filename, opts) do
    claims = if filename, do: %{"k" => key, "f" => filename}, else: %{"k" => key}
    ttl = Keyword.get(opts, :expires_in, @default_ttl_seconds)
    token = Phoenix.Token.sign(signer(opts), @salt, claims, max_age: ttl)

    path(key, opts) <> "?" <> URI.encode_query(%{"token" => token})
  end

  @doc false
  # The path the plug is forwarded at, without a trailing slash.
  def at(opts), do: opts |> option(:at, @default_at) |> String.trim_trailing("/")

  defp path(key, opts), do: at(opts) <> "/" <> encode_key(key)

  defp encode_key(key) do
    key
    |> String.split("/")
    |> Enum.map_join("/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))
  end

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

  defp signer(opts) do
    case {option(opts, :secret_key_base), option(opts, :endpoint)} do
      {secret, _endpoint} when is_binary(secret) ->
        secret

      {nil, endpoint} when is_atom(endpoint) and not is_nil(endpoint) ->
        endpoint

      _missing ->
        raise ArgumentError,
              "AshQuick.Storage.Local needs an :endpoint (or a :secret_key_base) to sign " <>
                "private links with: config :ash_quick, AshQuick.Storage.Local, " <>
                "endpoint: MyAppWeb.Endpoint"
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

    import Elixir.Plug.Conn

    alias AshQuick.Storage.Local

    # Shown inline: what a browser renders without running anything. SVG is an
    # image that can carry script, so it is downloaded like any other document.
    @inline ~w(audio video)
    @inline_types ~w(application/pdf text/plain)

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%Elixir.Plug.Conn{method: method} = conn, opts) when method in ["GET", "HEAD"] do
      with {:ok, key} <- key(conn.path_info),
           true <- Local.safe_key?(key),
           {:ok, disposition} <- grant(conn, key, opts) do
        serve(conn, key, disposition, opts)
      else
        _refused -> not_found(conn)
      end
    end

    def call(conn, _opts), do: not_found(conn)

    # `path_info` arrives as the request wrote it, percent-encoded, while a key
    # and the token naming it are not. A malformed escape is no key at all.
    defp key(path_info) do
      {:ok, Enum.map_join(path_info, "/", &URI.decode/1)}
    rescue
      ArgumentError -> :error
    end

    # Anchored, as `AshQuick.Storage` reads visibility: a `public/` under some
    # other prefix is private.
    # A public object needs no token; one that comes with a good token keeps
    # the filename it names.
    defp grant(conn, "public/" <> _rest = key, opts) do
      with token when is_binary(token) <- token(conn),
           {:ok, filename} <- Local.verify(key, token, opts) do
        {:ok, filename}
      else
        _none -> {:ok, nil}
      end
    end

    defp grant(conn, key, opts) do
      case token(conn) do
        token when is_binary(token) -> Local.verify(key, token, opts)
        _missing -> :error
      end
    end

    defp token(conn), do: fetch_query_params(conn).query_params["token"]

    defp serve(conn, key, filename, opts) do
      media_type = MIME.from_path(key)

      conn =
        conn
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("content-security-policy", csp(media_type))
        |> put_resp_header("content-disposition", disposition(filename, key, media_type))

      static =
        Elixir.Plug.Static.init(
          at: "/",
          from: Local.root(opts),
          cache_control_for_etags: cache_control(key),
          gzip: false,
          brotli: false
        )

      # `Plug.Static` decodes each segment again, so it is handed them encoded:
      # a key naming `100%.png` is the file `100%.png`, not a decoding error.
      served =
        conn
        |> Map.put(:path_info, key |> String.split("/") |> Enum.map(&encode_segment/1))
        |> Elixir.Plug.Static.call(static)

      if served.halted, do: served, else: not_found(conn)
    end

    defp encode_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

    # A PDF viewer will not open a sandboxed document, and it runs no script of
    # the page's origin, so it is left out of the sandbox.
    defp csp("application/pdf"), do: "default-src 'none'; style-src 'unsafe-inline'"
    defp csp(_media_type), do: "default-src 'none'; style-src 'unsafe-inline'; sandbox"

    defp cache_control("public/" <> _rest), do: "public"
    defp cache_control(_key), do: "private"

    defp disposition(nil, key, media_type) do
      if inline?(media_type),
        do: "inline",
        else: AshQuick.Storage.attachment_disposition(Path.basename(key))
    end

    defp disposition(filename, _key, _media_type),
      do: AshQuick.Storage.attachment_disposition(filename)

    defp inline?("image/svg+xml"), do: false
    defp inline?("image/" <> _subtype), do: true
    defp inline?(media_type) when media_type in @inline_types, do: true

    defp inline?(media_type),
      do: media_type |> String.split("/") |> hd() |> then(&(&1 in @inline))

    defp not_found(conn) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Not Found")
      |> halt()
    end
  end
end
