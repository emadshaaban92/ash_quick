defmodule AshQuick.Storage do
  @moduledoc """
  Resolves `AshQuick.AshTypes.Attachment.Value` records to fetchable URLs.

  Visibility is read from the value's `key` prefix — the same source of
  truth the bucket policy enforces against (see "Bucket policy
  contract" below). Callers don't pass constraints; the key already
  says everything we need.

    * `public/...`  → the storage module is asked for a `:public` URL. For
                      `AshQuick.Storage.S3` that is a deterministic HTTPS URL
                      pointing at the bucket, read anonymously through the
                      bucket policy.
    * any other prefix → it is asked for a `:private` URL: a short-lived,
                      signed one (S3: a presigned `GET`).

  ## Bucket policy contract

  AshQuick assumes a single S3-compatible bucket, reached through the
  storage seam below. Visibility is determined by the key prefix and
  enforced by a bucket policy on the host side. The host application is
  responsible for:

    * Provisioning the bucket as private at creation (deny-by-default).
    * Applying a bucket policy that grants anonymous `GetObject` on the
      `public/*` prefix and nothing else.
    * Ensuring "Block Public Access" (or equivalent) does not prevent
      that policy from taking effect.

  The exact policy syntax is provider-specific. The contract this
  module depends on is:

    * Reads under `public/*` succeed without authentication.
    * Reads under any other prefix fail without authentication;
      signed URLs minted here succeed.

  Bucket-policy-only access control is intentional: per-object ACLs are
  not used. `AshQuick.Storage.S3` never sets an ACL, and the upload
  pipeline picks the key prefix from the field's `:visibility`
  constraint. The path is the single source of truth — `public/...`
  is public, everything else is private. Per-object ACLs are deprecated
  in modern S3 deployments; bucket policies are the recommended
  boundary.

  A two-bucket split (one fully public, one fully private) gives a
  stronger isolation invariant; the single-bucket-with-prefix model is
  the chosen tradeoff for now. Migrating later is contained: copy
  `private/*` to a new bucket and swap the bucket name here based on
  visibility — no other code touched.

  ## Authorization

  Signed URLs piggy-back on existing Ash policies. A user who can
  `read` the parent resource gets signed URLs for its private
  attachments at render/serialize time; one who can't never reaches
  the rendering code. No new auth surface — the generated URL is a
  short-lived per-render capability token, gated by the policy that
  decided to render in the first place.

  Signed URLs are bearer tokens for their TTL window: anyone holding
  the URL (a user who has since lost access, or a recipient the URL
  was forwarded to) can fetch the object until it expires. This is
  the standard property of presigned URLs; we rely on the short TTL
  to bound exposure. The `:expires_in` option lets callers tighten
  the window further when warranted.

  ## Not every object is servable

  `url_for/2` also asks the host whether it is still holding the object,
  so a caller that renders it cannot forget to check — hence the
  `{:ok, url} | :processing | :rejected` return. A storage module without
  the lifecycle callbacks below answers `:ready` for everything and the
  only reachable clause is `{:ok, url}`.

  This is a **rendering** gate, not the security boundary. The boundary
  is the key: an object the host has not released is not at the key
  this module signs, so an ungated fetch would 404. The state read is
  what turns that into a placeholder rather than a broken image.

  Reading state costs a lookup per key, so a caller rendering several
  attachments passes `states_for/2` once via `:states` rather than
  paying it per image.

  ## The storage seam

  Everything that needs a bucket, a host or credentials is a callback, worded
  as what AshQuick wants done rather than as one store's operations:

    * `c:url/2` — a URL a page can render an object from.
    * `c:download_url/2` — a URL that downloads an object under a filename.
    * `c:put_file/3` — store a file the server holds (an export, say).
    * `c:upload_target/2` — where a browser sends a picked file. Optional:
      a storage module without it receives uploads through the LiveView
      socket, and AshQuick writes each one with `c:put_file/3`.

  What stays here is the part that reads a key rather than a bucket — which
  prefix is public, and whether the host is still holding the object.

  The default implementation is `AshQuick.Storage.S3` (plain ExAws, bucket
  from `AshQuick.Config.s3_bucket/0`). A host that already owns an
  object-store client points the seam at it and keeps one bucket across
  both:

      config :ash_quick, storage: MyApp.Uploads.ObjectStore

  ## Browser uploads

  A picked file goes one of two ways, chosen by whether the storage module
  exports `c:upload_target/2`:

    * **External.** The browser writes the bytes straight to the store.
      `c:upload_target/2` returns the name of a LiveView client uploader and
      the metadata it needs; AshQuick ships one, `S3`, as colocated JS that
      the host registers on its `LiveSocket`:

          import { hooks as ashQuickHooks, uploaders as ashQuickUploaders }
            from "phoenix-colocated/ash_quick"

          let liveSocket = new LiveSocket("/live", Socket, {
            hooks: {...ashQuickHooks},
            uploaders: {...ashQuickUploaders}
          })

    * **Socket.** Without `c:upload_target/2` the bytes travel over the
      LiveView socket to the server, and AshQuick hands the finished file to
      `c:put_file/3` once the entry completes. Nothing needs registering in
      the browser. `c:put_file/3` runs in the LiveView process, so the page
      waits on the store while it writes. A file the store refuses is left
      off the form, and the page flashes that it was not uploaded.

  ## Object lifecycle

  The same module is the host's hook into the life of an uploaded object.
  AshQuick knows where an object belongs (the key, derived from the field's
  `:visibility` constraint) and what the field expects of it (`:accepts`,
  `:max_size_mb`). It does not know what the host wants to *do* with an
  object before serving it — scan it, transcode it, or nothing at all. The
  three optional callbacks `object_arriving/2`, `object_states/2` and
  `object_referenced/4` are that seam, worded in terms of object lifecycle
  rather than any one of those.

  A storage module that leaves them out gets the passthrough: bytes go
  straight to the key they were destined for and every object is servable.
  `AshQuick.Storage.S3` implements none of them, so a host that wants none
  of it configures nothing.

  ### Why the host chooses the storage key

  `object_arriving/2` is told the **serving** key — where the object has to
  end up for `url_for/2` to resolve it — and answers with the key the bytes
  should actually be written to. A host that holds objects somewhere else
  first (a quarantine prefix, a staging bucket) says so here, and AshQuick
  writes the bytes to whatever it is handed: `c:upload_target/2` is asked
  for that key, and so is `c:put_file/3`. Nothing in AshQuick has to learn
  the layout, and the record it saves keeps pointing at the serving key
  throughout.

  A host that intercepts the key is then responsible for getting the object
  to the serving key; until it does, `object_states/2` is how it says so.

  ### Who is asking

  Every lifecycle callback is handed the request's `:scope` in its opts, so a
  host can do its work as the person behind it — read through their policies,
  stamp them on what it records — rather than as nobody or a platform bot.
  The scope is whatever the surface was mounted with; outside a request (a
  seed, a job) it is `nil`, and the host decides what that means.

  `object_states/1` and `object_referenced/3`, the arities from before the
  scope was passed, are still called for a storage module that exports them
  and not the newer one.
  """

  alias AshQuick.AshTypes.Attachment.Value

  @default_ttl_seconds 3600

  @typedoc "An object-storage key."
  @type key :: String.t()

  @typedoc """
  How servable an object is.

    * `:ready` — every required processing step finished; serve it.
    * `:processing` — not yet; the object is not at its serving key.
    * `:rejected` — the host refused it; it will never be servable.
  """
  @type state :: :ready | :processing | :rejected

  @typedoc """
  A URL, or why there isn't one — see `t:state/0`.
  """
  @type resolution :: {:ok, String.t()} | :processing | :rejected

  @typedoc """
  Where a browser sends a picked file: the name of a LiveView client uploader
  registered on the host's `LiveSocket`, and the metadata that uploader reads
  (`entry.meta` in the browser). AshQuick adds `:key` and `:serving_key` to it.
  """
  @type upload_target :: {:external, uploader :: String.t(), meta :: map()}

  @doc """
  A URL a page renders `key` from.

  Options:

    * `:visibility` — `:public` for a `public/*` key, `:private` for any
      other. A `:public` URL may be permanent and unauthenticated; a
      `:private` one has to stop working after `:expires_in`.
    * `:expires_in` — TTL in seconds for a `:private` URL. Defaults to
      `#{@default_ttl_seconds}` (1 hour).
  """
  @callback url(key(), opts :: keyword()) :: String.t()

  @doc """
  A URL that downloads `key` as a file named `:filename`, rather than showing
  it in the browser. Exports are handed out through it.

  Options:

    * `:filename` — the name the browser saves the file under. Required.
    * `:expires_in` — TTL in seconds. Defaults to `#{@default_ttl_seconds}`.
  """
  @callback download_url(key(), opts :: keyword()) :: String.t()

  @doc """
  Stores the local file at `path` under `key`. Used for an object the server
  holds: a generated export, or a browser upload that arrived over the socket
  (see "Browser uploads" above).

  Options:

    * `:content_type` — the object's media type, when known.
  """
  @callback put_file(key(), path :: Path.t(), opts :: keyword()) :: :ok | {:error, term()}

  @doc """
  Where the browser writes a picked file destined for `key`. See "Browser
  uploads" above.

  Called once per picked file, after `c:object_arriving/2`, with the key that
  answered. The target has to bind what AshQuick was told about the file, so
  a browser cannot store something else under the key:

    * `:content_type` — the type the browser declared.
    * `:content_length` — the size the browser declared, in bytes.
      `max_file_size` on `allow_upload/3` only bounds what the browser
      offers, so this is the server-side size cap: the store must refuse a
      body of any other length. `AshQuick.Storage.S3` signs it as a header,
      which makes a differently sized `PUT` fail signature validation.
    * `:expires_in` — how long the target may be used, in seconds.

  Optional; left out, uploads come over the LiveView socket and are stored
  with `c:put_file/3`.
  """
  @callback upload_target(key(), opts :: keyword()) :: upload_target()

  @doc """
  An object is arriving at `serving_key`. Returns the key to write the bytes to.

  Called once per object, before the bytes are written: when the file is picked
  for an external browser upload, and immediately before `c:put_file/3` for an
  upload that came over the socket. This is the
  host's chance to record the object, and to say where it wants the bytes. A
  host that would rather not work on an object until something references it can
  wait for `c:object_referenced/4` — a picked file is not a saved one.

  `opts` carries what the surface knows, all optional:

    * `:accepts` — the field's allowed media classes (`[:image, :video, :document]`)
    * `:max_bytes` — the field's size cap, in bytes
    * `:content_type`, `:byte_size` — as the client declared them
    * `:filename` — the original filename
    * `:source` — which surface this is, e.g. `:upload_form`
    * `:resource` — the resource module the field belongs to
    * `:resource_id` — its id, when the record already exists
    * `:scope` — the host's request scope, for attribution

  Optional; left out, the bytes go to `serving_key`.
  """
  @callback object_arriving(serving_key :: key(), opts :: keyword()) ::
              {:ok, key()} | {:error, term()}

  @doc """
  States for `keys`, in one read.

  Only keys the host holds state for need appear. A key that is absent from the
  answer is treated as `:ready` — an object the host never took custody of is
  one it has no reason to withhold.

  This is on the render path, once per attachment field, so it reads for
  whoever is looking at the page. `opts`:

    * `:scope` — the host's request scope, `nil` outside a request

  Optional; left out, every object is `:ready`. A module exporting only the
  older `object_states/1` is called with `keys` alone.
  """
  @callback object_states(keys :: [key()], opts :: keyword()) :: %{optional(key()) => state()}

  @doc "The arity before `opts` was passed. Prefer `c:object_states/2`."
  @callback object_states(keys :: [key()]) :: %{optional(key()) => state()}

  @doc """
  A saved record now references `keys`.

  Called after a record carrying attachments is created or updated, so the host
  can tell an object that was attached to something from one whose form was
  abandoned. With `auto_upload: true` the bytes are in storage from the moment a
  file is picked, so this is the only signal that anything came back for them.

  It runs inside the save, so it acts for whoever saved. `opts`:

    * `:scope` — the scope the form was submitted with

  Optional; left out, the reference is `:ok` and nothing is recorded. A module
  exporting only the older `object_referenced/3` is called without `opts`.
  """
  @callback object_referenced(
              keys :: [key()],
              resource :: module(),
              resource_id :: term(),
              opts :: keyword()
            ) :: :ok | {:error, term()}

  @doc "The arity before `opts` was passed. Prefer `c:object_referenced/4`."
  @callback object_referenced(keys :: [key()], resource :: module(), resource_id :: term()) ::
              :ok | {:error, term()}

  @optional_callbacks upload_target: 2,
                      object_arriving: 2,
                      object_states: 2,
                      object_states: 1,
                      object_referenced: 4,
                      object_referenced: 3

  @doc """
  Returns `{:ok, url}` for the given attachment value, or `:processing` /
  `:rejected` when the host is not serving that object.

  Options:

    * `:states` — a `%{key => state}` map from `states_for/2`, treated as
      authoritative: a key absent from it is `:ready`. Pass this when
      rendering more than one attachment; without it each call costs its
      own lookup.
    * `:scope` — the request scope the lookup is made for, when `:states`
      is not given. See `c:object_states/2`.
    * `:variant` — which rendition to serve. Only `:original` (the
      default) exists today; anything else raises. The argument is here
      so a host that later derives renditions has somewhere to ask for
      one without every call site changing shape.
    * `:expires_in` — TTL in seconds for a private URL. Defaults to
      `#{@default_ttl_seconds}` (1 hour). See `c:url/2`.
  """
  @spec url_for(Value.t(), keyword()) :: resolution()
  def url_for(value, opts \\ [])

  def url_for(%Value{key: key} = value, opts) when is_binary(key) do
    validate_variant!(Keyword.get(opts, :variant, :original))

    case state(key, opts) do
      :ready -> {:ok, serving_url(value, opts)}
      withheld -> withheld
    end
  end

  @doc """
  States for a batch of attachment values (or bare keys), in one read.

  Keys the host holds no state for are absent from the result, which
  `url_for/2` reads as `:ready`.

  Pass `scope:` — the page's request scope — so the host reads for whoever is
  looking. See `c:object_states/2`.
  """
  @spec states_for([Value.t() | String.t()], keyword()) :: %{optional(key()) => state()}
  def states_for(values, opts \\ []) do
    values
    |> Enum.flat_map(fn
      %Value{key: key} when is_binary(key) -> [key]
      key when is_binary(key) -> [key]
      _other -> []
    end)
    |> Enum.uniq()
    |> object_states(Keyword.take(opts, [:scope]))
  end

  @doc """
  Every attachment key `record` holds, including the ones inside embedded
  resources.

  The record holding the key inside its attachment value is the authoritative
  direction — record → key — so this is what a caller with a record in hand and
  a question about its objects walks. Only attributes are walked: an attachment
  always lives inside the record, never behind a relationship, so there is
  nothing to load and no cycle to guard against.
  """
  @spec attachment_keys(struct() | nil) :: [String.t()]
  def attachment_keys(%resource{} = record) do
    if Ash.Resource.Info.resource?(resource) do
      resource
      |> Ash.Resource.Info.attributes()
      |> Enum.flat_map(&keys_in(Map.get(record, &1.name)))
      |> Enum.uniq()
    else
      []
    end
  end

  def attachment_keys(_record), do: []

  @doc false
  # Every attachment key inside one attribute's value: an attachment, a list of
  # them, or a union, a typed map or an embed holding any of those.
  def keys_in(%Value{key: key}) when is_binary(key), do: [key]
  def keys_in(values) when is_list(values), do: Enum.flat_map(values, &keys_in/1)
  def keys_in(%Ash.Union{value: value}), do: keys_in(value)

  def keys_in(values) when is_map(values) and not is_struct(values),
    do: values |> Map.values() |> keys_in()

  # Everything else a struct-valued attribute can hold — a `DateTime`, an
  # `Ash.NotLoaded`, a `Money` — is not an Ash resource and stops the walk here.
  def keys_in(%resource{} = embedded) do
    if Ash.Resource.Info.resource?(resource) and Ash.Resource.Info.embedded?(resource),
      do: attachment_keys(embedded),
      else: []
  end

  def keys_in(_value), do: []

  # A prefetched map is the whole batch, so a missing key means "no state
  # held" rather than "not fetched yet".
  defp state(key, opts) do
    case Keyword.fetch(opts, :states) do
      {:ok, states} -> Map.get(states, key, :ready)
      :error -> Map.get(object_states([key], Keyword.take(opts, [:scope])), key, :ready)
    end
  end

  defp validate_variant!(:original), do: :ok

  defp validate_variant!(variant) do
    raise ArgumentError,
          "unknown attachment variant #{inspect(variant)}; only :original is served today"
  end

  defp serving_url(%Value{key: key}, opts) do
    impl().url(key, [visibility: visibility(key)] ++ Keyword.take(opts, [:expires_in]))
  end

  # Anchored, so a `public/` nested under another prefix (a quarantine, say)
  # is private.
  defp visibility("public/" <> _rest), do: :public
  defp visibility(_key), do: :private

  @doc """
  How the configured storage module takes browser uploads: `:external` when it
  exports `c:upload_target/2`, `:socket` when it does not.
  """
  @spec upload_mode() :: :external | :socket
  def upload_mode do
    impl = impl()

    if Code.ensure_loaded?(impl) and function_exported?(impl, :upload_target, 2),
      do: :external,
      else: :socket
  end

  @doc "See `c:upload_target/2`."
  @spec upload_target(key(), keyword()) :: upload_target()
  def upload_target(key, opts \\ []) when is_binary(key), do: impl().upload_target(key, opts)

  @doc """
  A download URL for an arbitrary key — a server-generated object such as an
  export, which has no `Value` to hand to `url_for/2`. See `c:download_url/2`.
  """
  @spec download_url(key(), keyword()) :: String.t()
  def download_url(key, opts) when is_binary(key) do
    case Keyword.get(opts, :filename) do
      filename when is_binary(filename) and filename != "" -> impl().download_url(key, opts)
      _missing -> raise ArgumentError, "download_url/2 needs a :filename to download as"
    end
  end

  @doc "See `c:put_file/3`."
  @spec put_file(key(), Path.t(), keyword()) :: :ok | {:error, term()}
  def put_file(key, path, opts \\ []) when is_binary(key) and is_binary(path),
    do: impl().put_file(key, path, opts)

  @doc "See `c:object_arriving/2`. The passthrough answer is `serving_key` itself."
  def object_arriving(serving_key, opts \\ []),
    do: lifecycle(:object_arriving, [serving_key, opts], {:ok, serving_key})

  @doc "See `c:object_states/2`. The passthrough answer withholds nothing."
  def object_states(keys, opts \\ [])
  def object_states([], _opts), do: %{}
  def object_states(keys, opts), do: lifecycle(:object_states, [keys], opts, %{})

  @doc "See `c:object_referenced/4`. The passthrough answer is `:ok`."
  def object_referenced(keys, resource, resource_id, opts \\ [])
  def object_referenced([], _resource, _resource_id, _opts), do: :ok

  def object_referenced(keys, resource, resource_id, opts),
    do: lifecycle(:object_referenced, [keys, resource, resource_id], opts, :ok)

  defp impl, do: AshQuick.Config.storage()

  # The lifecycle callbacks are optional, so a storage module that leaves one
  # out is answered for it here rather than made to say "nothing" three times.
  defp lifecycle(callback, args, passthrough) do
    impl = impl()

    if Code.ensure_loaded?(impl) and function_exported?(impl, callback, length(args)),
      do: apply(impl, callback, args),
      else: passthrough
  end

  # `object_states` and `object_referenced` took no opts before the scope was
  # passed. A module written against that arity is still called with it, so
  # adding `opts` is not a change every host has to make on the same day.
  defp lifecycle(callback, args, opts, passthrough) do
    impl = impl()
    Code.ensure_loaded?(impl)

    cond do
      function_exported?(impl, callback, length(args) + 1) ->
        apply(impl, callback, args ++ [opts])

      function_exported?(impl, callback, length(args)) ->
        apply(impl, callback, args)

      true ->
        passthrough
    end
  end

  defmodule S3 do
    @moduledoc """
    The default `AshQuick.Storage` implementation: plain ExAws against
    `AshQuick.Config.s3_bucket/0` and `AshQuick.Config.s3_host/0`.

    Browser uploads are external: `upload_target/2` hands the browser a
    presigned `PUT` for the `S3` client uploader AshQuick ships (see "Browser
    uploads" in `AshQuick.Storage`).

    Every callback also takes `:bucket` and `:host` in its opts, over the
    configured ones. They are for a host whose own object-store seam owns the
    bucket: it points `:storage` at itself and delegates here with its own
    bucket, so signing and key encoding are stated once rather than restated
    per host:

        def url(key, opts), do: AshQuick.Storage.S3.url(key, [bucket: "mine"] ++ opts)
    """
    @behaviour AshQuick.Storage

    @default_ttl_seconds 3600

    @impl true
    def url(key, opts) do
      case Keyword.get(opts, :visibility, :private) do
        :public -> public_url(key, opts)
        :private -> presigned_get_url(key, opts)
      end
    end

    @impl true
    def download_url(key, opts) do
      filename = Keyword.fetch!(opts, :filename)

      presigned_get_url(
        key,
        Keyword.put(opts, :query_params, [
          {"response-content-disposition", content_disposition(filename)}
        ])
      )
    end

    @impl true
    def put_file(key, path, opts) do
      s3_opts =
        case Keyword.get(opts, :content_type) do
          nil -> []
          content_type -> [content_type: content_type]
        end

      path
      |> ExAws.S3.Upload.stream_file()
      |> ExAws.S3.upload(bucket(opts), key, s3_opts)
      |> ExAws.request()
      |> case do
        {:ok, _} -> :ok
        {:error, term} -> {:error, term}
      end
    end

    @doc """
    A presigned `PUT` for the `S3` client uploader.

    `:content_type` travels as a signed query parameter, which keeps the value
    tamper-proof but binds nothing: S3 ignores query parameters it does not
    recognise, so the stored type is the `Content-Type` header the uploader
    sends. `:content_length` is signed as a **header**, so it appears in
    `X-Amz-SignedHeaders` and the value is part of the canonical request. A
    `PUT` whose body is a different length sends a different `Content-Length`
    and fails signature validation, which is what makes the size cap a
    server-side one. Signing it as a query parameter instead would bind
    nothing, for the reason above.
    """
    @impl true
    def upload_target(key, opts) do
      url =
        presigned_url(bucket(opts), :put, key,
          expires_in: ttl(opts),
          query_params: maybe_param([], "Content-Type", Keyword.get(opts, :content_type)),
          headers: maybe_param([], "content-length", Keyword.get(opts, :content_length))
        )

      {:external, "S3", %{url: url}}
    end

    @doc """
    The anonymous-read URL for `key`. No signing: the bucket policy is what
    makes the read succeed. Opts: `:bucket`, `:host`.
    """
    def public_url(key, opts \\ []) do
      host = Keyword.get_lazy(opts, :host, &AshQuick.Config.s3_host/0)
      "https://#{bucket(opts)}.#{host}/#{encode_key(key)}"
    end

    @doc """
    A presigned `GET` for `key`. Opts: `:bucket`, `:expires_in`, and
    `:query_params`, extra signed query params such as
    `response-content-disposition`.
    """
    def presigned_get_url(key, opts \\ []) do
      presigned_url(bucket(opts), :get, key,
        expires_in: ttl(opts),
        query_params: Keyword.get(opts, :query_params, [])
      )
    end

    defp bucket(opts), do: Keyword.get_lazy(opts, :bucket, &AshQuick.Config.s3_bucket/0)

    defp ttl(opts), do: Keyword.get(opts, :expires_in, @default_ttl_seconds)

    defp maybe_param(params, _name, nil), do: params
    defp maybe_param(params, name, value), do: [{name, to_string(value)} | params]

    # RFC 6266: a plain-ASCII `filename` for old clients, with quotes and
    # backslashes dropped so it cannot end the quoted string early, and the
    # exact name in `filename*` for every client that reads it.
    defp content_disposition(filename) do
      fallback =
        filename
        |> String.replace(~r/[^\x20-\x7E]|["\\]/u, "_")

      encoded = URI.encode(filename, &URI.char_unreserved?/1)
      ~s(attachment; filename="#{fallback}"; filename*=UTF-8''#{encoded})
    end

    defp encode_key(key) do
      key
      |> String.split("/")
      |> Enum.map_join("/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))
    end

    defp presigned_url(bucket, method, key, opts) do
      config = ExAws.Config.new(:s3)

      {:ok, url} =
        ExAws.S3.presigned_url(config, method, bucket, key, [virtual_host: true] ++ opts)

      url
    end
  end
end
