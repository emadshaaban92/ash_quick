defmodule AshQuick.Storage.Served do
  @moduledoc false
  # What the stores that serve objects from the application's own origin share:
  # `AshQuick.Storage.Local` and `AshQuick.Storage.S3.Proxy`.
  #
  # A link is the plug's path plus the key, and, for anything but a `public/*`
  # key, a `Phoenix.Token` naming the key (and the filename a download saves
  # under). The plug side reads the key back off the request, checks the token
  # and stamps the headers that keep an uploaded file from running as a page
  # of the application.
  #
  # Every function takes `owner`, the store whose `config :ash_quick, owner`
  # holds `:at`, `:endpoint` and `:secret_key_base`, so each store keeps its
  # own configuration.

  import Plug.Conn

  @default_ttl_seconds 3600
  @default_at "/ash_quick/files"
  @salt "ash_quick storage"

  # Shown inline: what a browser renders without running anything. SVG is an
  # image that can carry script, so it is downloaded like any other document.
  @inline ~w(audio video)
  @inline_types ~w(application/pdf text/plain)

  @doc false
  def option(owner, opts, name, default \\ nil) do
    Keyword.get_lazy(opts, name, fn ->
      :ash_quick |> Application.get_env(owner, []) |> Keyword.get(name, default)
    end)
  end

  @doc false
  # The path the plug is forwarded at, without a trailing slash.
  def at(owner, opts), do: owner |> option(opts, :at, @default_at) |> String.trim_trailing("/")

  @doc false
  def url(owner, key, opts) do
    case Keyword.get(opts, :visibility, :private) do
      :public -> path(owner, key, opts)
      :private -> signed(owner, key, nil, opts)
    end
  end

  @doc false
  def download_url(owner, key, opts),
    do: signed(owner, key, Keyword.fetch!(opts, :filename), opts)

  @doc false
  # What a token names, or `:error`. A token minted for another key does not
  # open this one.
  def verify(owner, key, token, opts) do
    case Phoenix.Token.verify(signer(owner, opts), @salt, token) do
      {:ok, %{"k" => ^key} = claims} -> {:ok, Map.get(claims, "f")}
      _invalid -> :error
    end
  end

  defp signed(owner, key, filename, opts) do
    claims = if filename, do: %{"k" => key, "f" => filename}, else: %{"k" => key}
    ttl = Keyword.get(opts, :expires_in, @default_ttl_seconds)
    token = Phoenix.Token.sign(signer(owner, opts), @salt, claims, max_age: ttl)

    path(owner, key, opts) <> "?" <> URI.encode_query(%{"token" => token})
  end

  defp path(owner, key, opts), do: at(owner, opts) <> "/" <> encode_key(key)

  defp encode_key(key) do
    key
    |> String.split("/")
    |> Enum.map_join("/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))
  end

  defp signer(owner, opts) do
    case {option(owner, opts, :secret_key_base), option(owner, opts, :endpoint)} do
      {secret, _endpoint} when is_binary(secret) ->
        secret

      {nil, endpoint} when is_atom(endpoint) and not is_nil(endpoint) ->
        endpoint

      _missing ->
        raise ArgumentError,
              "#{inspect(owner)} needs an :endpoint (or a :secret_key_base) to sign " <>
                "private links with: config :ash_quick, #{inspect(owner)}, " <>
                "endpoint: MyAppWeb.Endpoint"
    end
  end

  ## The plug side

  @doc false
  # `path_info` arrives as the request wrote it, percent-encoded, while a key
  # and the token naming it are not. A malformed escape is no key at all, and
  # neither is one `safe_key?/1` refuses: it is checked here, before any grant,
  # so no plug can skip it.
  def request_key(%Plug.Conn{path_info: path_info}) do
    key = Enum.map_join(path_info, "/", &URI.decode/1)
    if safe_key?(key), do: {:ok, key}, else: :error
  rescue
    ArgumentError -> :error
  end

  @doc false
  # A key that names one object and no other. A `.` or `..` segment is
  # resolved away by whatever reads the key next (a file system, or the HTTP
  # client that asks the bucket), so `public/../private/x` would be granted as
  # a `public/` key and read as a private one. An empty segment, a backslash
  # or a NUL byte is refused for the same reason. Decoded first, so an encoded
  # `%2E%2E` or `%2F` is refused as what it decodes to.
  #
  # Anchored by segment, so a name that merely contains dots (`a..b.jpg`) is
  # fine while `..` on its own is not. `Path.safe_relative/1` would accept
  # `a/../b` by collapsing it into another key.
  def safe_key?(key) when is_binary(key) and key != "" do
    String.valid?(key) and not String.contains?(key, ["\\", <<0>>]) and
      key |> String.split("/") |> Enum.all?(&(&1 not in ["", ".", ".."]))
  end

  def safe_key?(_key), do: false

  @doc false
  # Anchored, as `AshQuick.Storage` reads visibility: a `public/` under some
  # other prefix is private. A public object needs no token; one that comes
  # with a good token keeps the filename it names.
  def grant(owner, conn, "public/" <> _rest = key, opts) do
    with token when is_binary(token) <- token(conn),
         {:ok, filename} <- verify(owner, key, token, opts) do
      {:ok, filename}
    else
      _none -> {:ok, nil}
    end
  end

  def grant(owner, conn, key, opts) do
    case token(conn) do
      token when is_binary(token) -> verify(owner, key, token, opts)
      _missing -> :error
    end
  end

  defp token(conn), do: fetch_query_params(conn).query_params["token"]

  @doc false
  # The headers every served object carries. The media type is read off the
  # key, never off what a browser declared when it uploaded the file.
  def put_object_headers(conn, key, filename) do
    media_type = MIME.from_path(key)

    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", csp(media_type))
    |> put_resp_header("content-disposition", disposition(filename, key, media_type))
  end

  @doc false
  def cache_control("public/" <> _rest), do: "public"
  def cache_control(_key), do: "private"

  # A PDF viewer will not open a sandboxed document, and it runs no script of
  # the page's origin, so it is left out of the sandbox.
  defp csp("application/pdf"), do: "default-src 'none'; style-src 'unsafe-inline'"
  defp csp(_media_type), do: "default-src 'none'; style-src 'unsafe-inline'; sandbox"

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

  @doc false
  def not_found(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Not Found")
    |> halt()
  end
end
