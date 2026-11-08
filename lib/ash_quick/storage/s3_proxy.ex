defmodule AshQuick.Storage.S3.Proxy do
  @moduledoc """
  An `AshQuick.Storage` over an S3-compatible bucket that only the application
  can reach.

  `AshQuick.Storage.S3` hands the browser the bucket itself: a presigned or
  public bucket URL to read an object from, and a presigned `PUT` to upload
  one. That needs a bucket the reader's browser can reach. This module keeps
  the browser on the application's origin instead:

    * every URL it hands out points at `AshQuick.Storage.S3.Proxy.Plug`, which
      reads the object from the bucket and streams it on;
    * browser uploads come over the LiveView socket, and the server writes
      them to the bucket with `AshQuick.Storage.S3.put_file/3`.

  So the bucket can sit on a private network, or deny every request that is
  not signed with the application's credentials. It needs no bucket policy
  for `public/*`, no CORS rules and nothing in a Content Security Policy.

  Every byte passes through the application twice, once on the way in and
  once on the way out, and an upload's write to the bucket holds the page
  until it finishes (see "Browser uploads" in `AshQuick.Storage`). Use
  `AshQuick.Storage.S3` for a bucket the browser can reach.

  ## Setting it up

      config :ash_quick, storage: AshQuick.Storage.S3.Proxy

      config :ash_quick, AshQuick.Storage.S3.Proxy,
        bucket: "my-app-uploads",
        endpoint: MyAppWeb.Endpoint

  and, in the router, outside any pipeline:

      forward "/ash_quick/files", AshQuick.Storage.S3.Proxy.Plug

  ExAws is configured as for `AshQuick.Storage.S3`: credentials, region and,
  for a store other than AWS, the `:s3` host under `config :ex_aws`. A bucket
  reached through another host or other credentials than the rest of the
  application's S3 traffic names them in `:ex_aws`.

  Options, read when they are used, so `config/runtime.exs` can set them:

    * `:bucket` — the bucket objects are kept in. Defaults to
      `AshQuick.Config.s3_bucket/0`.
    * `:endpoint` — the Phoenix endpoint whose `secret_key_base` signs the
      links handed out for private objects. Required unless
      `:secret_key_base` is given.
    * `:secret_key_base` — the key to sign with instead of an endpoint's.
    * `:at` — the path the plug is forwarded at, which every URL is built
      from. Defaults to `"/ash_quick/files"`. Inside a router `scope`, it is
      the full path the scope puts the forward at. `mix ash_quick.check`
      reports a router that does not forward it.
    * `:ex_aws` — overrides for every `ExAws` request this store makes, as
      `ExAws.request/2` takes them: `host:`, `scheme:`, `port:`,
      `access_key_id:` and the rest of the `:s3` service's configuration.
      Defaults to none, so `config :ex_aws` applies as it is.
    * `:chunk_size` — how many bytes the plug reads from the bucket per
      request while it streams an object. Defaults to 5 MiB, so a response
      holds at most that much of an object in memory at once.

  Set them in configuration: links are built from it, and the plug and
  `mix ash_quick.check` read it too, so a bucket or a secret given only on
  the router's forward leaves every link pointing at an object the plug looks
  for elsewhere, or a token it cannot verify. Each callback and the plug do
  take them in their opts as well, over the configured ones.

  ## Adding to it

  A host that wants the lifecycle callbacks (`c:AshQuick.Storage.object_arriving/2`
  and the rest) writes a module of its own and points `:storage` at that:

      defmodule MyApp.Uploads.Store do
        use AshQuick.Storage.S3.Proxy

        @impl true
        def object_arriving(serving_key, opts), do: ...
      end

  `use` delegates `url/2`, `download_url/2` and `put_file/3` here, each of
  them overridable, and marks the module as backed by this one, so
  `mix ash_quick.check` still holds the router to the forward.

  ## What a URL grants

  A `public/*` object is served to anyone who asks for its path. Every other
  object needs the token on its link: a `Phoenix.Token` naming the key, signed
  with the endpoint's secret and good for `:expires_in` seconds. Like a
  presigned URL, the link is a bearer capability until it expires, handed out
  only to a page that was allowed to render the object. A link with no token,
  a tampered or expired one, or one minted for another key answers `404`, and
  so does a key the bucket does not hold.

  A download link's token also carries the filename, so the browser saves the
  object under it rather than showing it.

  ## Keys

  A requested key is refused, before its link is checked, when it holds an
  empty segment, `.` or `..`, a backslash or a NUL byte, encoded or not. The
  HTTP client that asks the bucket resolves dot segments, so
  `public/../private/x` would otherwise be granted as a public key and read
  as a private one. So is a key holding a `?` or a `#`: ExAws splits the
  bucket's URL at the first `?`, so the rest would reach the bucket as
  signed query parameters (`versionId`, `acl`, `tagging`). `put_file/3`
  refuses the same keys, so nothing is stored that could not be served.

  ## Serving uploads from the application's origin

  An uploaded file is served from the same origin as the pages, so a file a
  browser would run (HTML, SVG, XML) must not be shown as one. Every response
  carries `x-content-type-options: nosniff` and a sandboxing
  `content-security-policy`, and only images (other than SVG), audio, video,
  PDFs and plain text are shown inline. Anything else is sent as an
  attachment. The media type is read off the key's extension, not off the
  type the object was stored with, which is the one the uploading browser
  declared.
  """
  @behaviour AshQuick.Storage

  alias AshQuick.Storage.Served

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour AshQuick.Storage

      @doc false
      def __ash_quick_s3_proxy__, do: true

      @impl AshQuick.Storage
      def url(key, opts), do: AshQuick.Storage.S3.Proxy.url(key, opts)

      @impl AshQuick.Storage
      def download_url(key, opts), do: AshQuick.Storage.S3.Proxy.download_url(key, opts)

      @impl AshQuick.Storage
      def put_file(key, path, opts), do: AshQuick.Storage.S3.Proxy.put_file(key, path, opts)

      defoverridable url: 2, download_url: 2, put_file: 3
    end
  end

  @doc """
  Whether `storage` keeps its objects through this module: it is this module,
  or it was written with `use AshQuick.Storage.S3.Proxy`.
  """
  @spec backs?(module()) :: boolean()
  def backs?(__MODULE__), do: true

  def backs?(storage) when is_atom(storage),
    do: Code.ensure_loaded?(storage) and function_exported?(storage, :__ash_quick_s3_proxy__, 0)

  def backs?(_storage), do: false

  @impl true
  def url(key, opts), do: Served.url(__MODULE__, key, opts)

  @impl true
  def download_url(key, opts), do: Served.download_url(__MODULE__, key, opts)

  @doc """
  Writes the file at `path` to `key` in the bucket, through
  `AshQuick.Storage.S3.put_file/3`. A key the plug would refuse to serve (see
  "Keys" above) is refused here too, with `{:error, :invalid_key}`.
  """
  @impl true
  def put_file(key, path, opts) do
    if safe_key?(key) do
      s3_opts = opts |> Keyword.put(:bucket, bucket(opts)) |> Keyword.put(:ex_aws, ex_aws(opts))
      AshQuick.Storage.S3.put_file(key, path, s3_opts)
    else
      {:error, :invalid_key}
    end
  end

  @doc false
  # `AshQuick.Storage.Served.safe_key?/1`, and no `?` or `#`. ExAws puts the
  # key into the bucket's URL as it is and splits that URL at the first `?`,
  # so `public/logo.png?versionId=old` would ask the bucket for an old
  # version (or the ACL, or the tags) of a public object, signed with the
  # application's credentials.
  def safe_key?(key), do: Served.safe_key?(key) and not String.contains?(key, ["?", "#"])

  @doc false
  def at(opts), do: Served.at(__MODULE__, opts)

  @doc false
  def bucket(opts) do
    case Served.option(__MODULE__, opts, :bucket) do
      bucket when is_binary(bucket) and bucket != "" -> bucket
      _unset -> AshQuick.Config.s3_bucket()
    end
  end

  @doc false
  def ex_aws(opts), do: Served.option(__MODULE__, opts, :ex_aws, [])

  defmodule Plug do
    @moduledoc """
    Serves the objects `AshQuick.Storage.S3.Proxy` stores, read from the bucket
    as they are sent.

    Forward to it at the storage's `:at` path, outside any pipeline: what
    opens an object is the link's token, not the session, and a pipeline that
    checks the `accept` header or a CSRF token gets in an image's way.

        forward "/ash_quick/files", AshQuick.Storage.S3.Proxy.Plug

    Answers `GET` and `HEAD`. The object is read with one `HEAD` and then
    ranged `GET`s of `:chunk_size` bytes, each sent on before the next is
    read. A request for a single byte range (a video seeking, a download
    resuming) is answered `206` with that range; one asking for several
    ranges gets the whole object. The bucket's `ETag` and `Last-Modified` are
    passed on, and an `if-none-match` naming the `ETag` is answered `304`. A
    range sent with an `if-range` that is not the object's `ETag` gets the
    whole object.

    A bucket that cannot be read answers `502`, and the reason is logged. A
    `403` from the bucket answers `404`, as S3 refuses a missing key it may
    not list, and is logged at debug level, since wrong credentials answer
    it too.
    Reads retry once, not ExAws's default ten times, so a reader is not kept
    waiting on a bucket that is down; `ex_aws: [retries: ...]` on the store
    sets it otherwise. Each ranged `GET` is pinned to the `ETag` the `HEAD`
    answered, so an object replaced mid-response ends it short rather than
    mixing two versions. A `HEAD` that `Plug.Head` turned into a `GET` is
    still answered without reading the object.
    Options given to the forward are read over the configured ones, but the
    links are built from configuration alone, so set `:bucket` and the
    signing secret there (see "Setting it up" in `AshQuick.Storage.S3.Proxy`).
    """
    @behaviour Elixir.Plug

    import Elixir.Plug.Conn

    require Logger

    alias AshQuick.Storage.S3.Proxy
    alias AshQuick.Storage.Served

    @default_chunk_size 5 * 1024 * 1024

    # A reader is waiting on every read, so a bucket that is down answers
    # `502` after one retry rather than ExAws's default ten. `:ex_aws` given
    # to the store wins.
    @read_ex_aws [retries: [max_attempts: 2, base_backoff_in_ms: 100, max_backoff_in_ms: 1_000]]

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%Elixir.Plug.Conn{method: method} = conn, opts) when method in ["GET", "HEAD"] do
      with {:ok, key} <- Served.request_key(conn),
           true <- Proxy.safe_key?(key),
           {:ok, filename} <- Served.grant(Proxy, conn, key, opts) do
        serve(conn, key, filename, opts)
      else
        _refused -> Served.not_found(conn)
      end
    end

    def call(conn, _opts), do: Served.not_found(conn)

    defp serve(conn, key, filename, opts) do
      bucket = Proxy.bucket(opts)
      ex_aws = Keyword.merge(@read_ex_aws, Proxy.ex_aws(opts))

      case head(bucket, ex_aws, key) do
        {:ok, object} ->
          source = {bucket, ex_aws, object.etag}

          conn
          |> Served.put_object_headers(key, filename)
          |> put_resp_header("content-type", MIME.from_path(key))
          |> put_resp_header("cache-control", Served.cache_control(key))
          |> put_resp_header("accept-ranges", "bytes")
          |> put_validators(object)
          |> respond(source, key, object, opts)

        :not_found ->
          Served.not_found(conn)

        {:error, reason} ->
          Logger.warning(
            "AshQuick.Storage.S3.Proxy could not read #{inspect(key)} from " <>
              "#{inspect(bucket)}: #{inspect(reason)}"
          )

          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(502, "Bad Gateway")
          |> halt()
      end
    end

    defp respond(conn, source, key, object, opts) do
      if fresh?(conn, object),
        do: conn |> send_resp(304, "") |> halt(),
        else: send_object(conn, source, key, object, opts)
    end

    defp send_object(conn, source, key, %{size: size} = object, opts) do
      case range(conn, object) do
        :unsatisfiable ->
          conn
          |> put_resp_header("content-range", "bytes */#{size}")
          |> send_resp(416, "")
          |> halt()

        {first, last} when first > 0 or last < size - 1 ->
          conn
          |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
          |> send_range(206, source, key, {first, last}, opts)

        _whole ->
          send_range(conn, 200, source, key, {0, size - 1}, opts)
      end
    end

    # An empty object has no byte to range over.
    defp send_range(conn, status, _source, _key, {0, -1}, _opts),
      do: conn |> put_resp_header("content-length", "0") |> send_resp(status, "") |> halt()

    defp send_range(conn, status, source, key, {first, last}, opts) do
      conn = put_resp_header(conn, "content-length", Integer.to_string(last - first + 1))

      if head_request?(conn) do
        conn |> send_resp(status, "") |> halt()
      else
        conn
        |> send_chunked(status)
        |> stream(source, key, first, last, chunk_size(opts))
        |> halt()
      end
    end

    # One ranged `GET` per chunk, each sent before the next is read. The status
    # is already on the wire, so a bucket that fails partway can only end the
    # response short, which the client sees against `content-length`.
    defp stream(conn, _source, _key, first, last, _size) when first > last, do: conn

    defp stream(conn, {name, ex_aws, etag} = source, key, first, last, size) do
      stop = min(first + size - 1, last)

      # Pinned to the `ETag` the `HEAD` answered, so an object replaced while
      # it is being sent ends the response short rather than mixing versions.
      read = [range: "bytes=#{first}-#{stop}"] ++ if(etag, do: [if_match: etag], else: [])

      with {:ok, %{body: body}} <-
             name |> ExAws.S3.get_object(key, read) |> ExAws.request(ex_aws),
           {:ok, conn} <- chunk(conn, body) do
        stream(conn, source, key, stop + 1, last, size)
      else
        # The client went away, as a seeking video does all the time.
        {:error, :closed} ->
          conn

        {:error, reason} ->
          Logger.warning(
            "AshQuick.Storage.S3.Proxy stopped sending #{inspect(key)} from " <>
              "#{inspect(name)} at byte #{first}: #{inspect(reason)}"
          )

          conn
      end
    end

    # `Plug.Head`, which a Phoenix endpoint runs before the router, turns a
    # `HEAD` into a `GET`; the adapter (Bandit, Cowboy, `Plug.Test`) still
    # holds the method the request was made with, and drops the body of a
    # `HEAD` response, so a body streamed for one would be read from the bucket
    # for nothing.
    defp head_request?(%Elixir.Plug.Conn{method: "HEAD"}), do: true
    defp head_request?(%Elixir.Plug.Conn{adapter: {_adapter, %{method: "HEAD"}}}), do: true
    defp head_request?(_conn), do: false

    defp head(bucket, ex_aws, key) do
      case bucket |> ExAws.S3.head_object(key) |> ExAws.request(ex_aws) do
        {:ok, %{headers: headers}} ->
          headers = Map.new(headers, fn {name, value} -> {String.downcase(name), value} end)

          case Integer.parse(Map.get(headers, "content-length", "")) do
            {size, ""} when size >= 0 ->
              {:ok,
               %{
                 size: size,
                 etag: Map.get(headers, "etag"),
                 last_modified: Map.get(headers, "last-modified")
               }}

            _unsized ->
              {:error, :no_content_length}
          end

        {:error, {:http_error, 404, _response}} ->
          :not_found

        # S3 answers 403 for a missing key when the credentials cannot list
        # the bucket, so it reads as a 404. Wrong credentials or a bucket
        # policy refusing the application answer it too, for every key, so it
        # is logged for whoever is looking for why nothing is served.
        {:error, {:http_error, 403, _response}} ->
          Logger.debug(
            "AshQuick.Storage.S3.Proxy was refused #{inspect(key)} by " <>
              "#{inspect(bucket)} (403), answering 404"
          )

          :not_found

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp put_validators(conn, object) do
      Enum.reduce([{"etag", object.etag}, {"last-modified", object.last_modified}], conn, fn
        {_name, nil}, conn -> conn
        {name, value}, conn -> put_resp_header(conn, name, value)
      end)
    end

    defp fresh?(_conn, %{etag: nil}), do: false

    defp fresh?(conn, %{etag: etag}) do
      conn
      |> get_req_header("if-none-match")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.any?(&(&1 in [etag, "*", "W/" <> etag]))
    end

    # RFC 9110 single ranges: `bytes=first-last`, `bytes=first-` and the
    # suffix `bytes=-length`. Anything else, several ranges included, is
    # answered with the whole object, which the RFC allows.
    defp range(conn, %{size: size, etag: etag}) do
      case {get_req_header(conn, "range"), get_req_header(conn, "if-range")} do
        {["bytes=" <> spec], if_range} when if_range in [[], [etag]] ->
          parse_range(String.trim(spec), size)

        # A resumed download of an object that has changed since: an
        # `If-Range` naming another validator (an `ETag` that is not the
        # object's, or a date) gets the whole object, so the client cannot
        # join two versions.
        _none ->
          :all
      end
    end

    defp parse_range(spec, size) do
      if String.contains?(spec, ",") do
        :all
      else
        case String.split(spec, "-", parts: 2) do
          ["", suffix] -> suffix_range(integer(suffix), size)
          [first, ""] -> bounded(integer(first), size - 1, size)
          [first, last] -> bounded(integer(first), integer(last), size)
          _malformed -> :all
        end
      end
    end

    defp suffix_range(nil, _size), do: :all
    defp suffix_range(0, _size), do: :unsatisfiable
    defp suffix_range(_length, 0), do: :unsatisfiable
    defp suffix_range(length, size), do: {max(size - length, 0), size - 1}

    defp bounded(nil, _last, _size), do: :all
    defp bounded(_first, nil, _size), do: :all
    defp bounded(first, _last, size) when first >= size, do: :unsatisfiable
    defp bounded(first, last, _size) when last < first, do: :all
    defp bounded(first, last, size), do: {first, min(last, size - 1)}

    defp integer(text) do
      case Integer.parse(text) do
        {value, ""} when value >= 0 -> value
        _other -> nil
      end
    end

    defp chunk_size(opts) do
      case Served.option(Proxy, opts, :chunk_size, @default_chunk_size) do
        size when is_integer(size) and size > 0 -> size
        _other -> @default_chunk_size
      end
    end
  end
end
