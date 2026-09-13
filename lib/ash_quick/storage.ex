defmodule AshQuick.Storage do
  @moduledoc """
  Resolves `AshQuick.AshTypes.Attachment.Value` records to fetchable URLs.

  Visibility is read from the value's `key` prefix — the same source of
  truth the bucket policy enforces against (see "Bucket policy
  contract" below). Callers don't pass constraints; the key already
  says everything we need.

    * `public/...`  → deterministic HTTPS URL pointing at the bucket.
                      Anonymous reads succeed via the bucket policy.
    * `private/...` → ExAws-signed `GET` URL with a short TTL.
    * any other prefix → presigned `GET` URL (treated as private).

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
  not used. `presigned_put_url/2` never sets an ACL, and the upload
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
  attachments passes `states_for/1` once via `:states` rather than
  paying it per image.

  ## The storage seam

  Everything that needs a bucket, a host or credentials is a callback:
  `public_url/1`, `presigned_put_url/2`, `presigned_get_url/2` and
  `upload/3`. What stays here is the part that reads a key rather than a
  bucket — which prefix is public, and whether the host is still holding
  the object.

  The default implementation is `AshQuick.Storage.S3` (plain ExAws, bucket
  from `AshQuick.Config.s3_bucket/0`). A host that already owns an
  object-store client points the seam at it and keeps one bucket across
  both:

      config :ash_quick, storage: MyApp.Uploads.ObjectStore

  ## Object lifecycle

  The same module is the host's hook into the life of an uploaded object.
  AshQuick knows where an object belongs (the key, derived from the field's
  `:visibility` constraint) and what the field expects of it (`:accepts`,
  `:max_size_mb`). It does not know what the host wants to *do* with an
  object before serving it — scan it, transcode it, or nothing at all. The
  three optional callbacks `object_arriving/2`, `object_states/1` and
  `object_referenced/3` are that seam, worded in terms of object lifecycle
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
  signs the PUT for whatever it is handed. Nothing in AshQuick has to learn
  the layout, and the record it saves keeps pointing at the serving key
  throughout.

  A host that intercepts the key is then responsible for getting the object
  to the serving key; until it does, `object_states/1` is how it says so.
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

  @doc """
  The anonymous-read URL for a `public/*` key. No signing — the bucket
  policy is what makes the read succeed.
  """
  @callback public_url(key :: String.t()) :: String.t()

  @doc """
  A presigned `PUT` URL for uploading to `key`.

  Options:

    * `:content_type` — travels as a signed query parameter, which keeps
      the value tamper-proof but binds nothing: S3 ignores query
      parameters it does not recognise, so the stored type is whatever
      `Content-Type` header the uploader chooses to send.
    * `:content_length` — signed as a **header**, so it appears in
      `X-Amz-SignedHeaders` and the value is part of the canonical
      request. A `PUT` whose body is a different length sends a
      different `Content-Length` and fails signature validation, which
      is what makes the size cap a server-side one. Signing it as a
      query parameter instead would bind nothing, for the reason above.
    * `:expires_in` — TTL in seconds. Defaults to
      `#{@default_ttl_seconds}` (1 hour).
  """
  @callback presigned_put_url(key :: String.t(), opts :: keyword()) :: String.t()

  @doc """
  A presigned `GET` URL for an arbitrary key.

  Options:

    * `:expires_in` — TTL in seconds. Defaults to `#{@default_ttl_seconds}`.
    * `:query_params` — extra signed query params, e.g.
      `[{"response-content-disposition", ~s(attachment; filename="x.csv")}]`
      to force a download with a chosen filename.
  """
  @callback presigned_get_url(key :: String.t(), opts :: keyword()) :: String.t()

  @doc """
  Streams a local file up to `key` (server-side `PUT`), for an object the
  host generated rather than one a browser uploaded. Opts: `:content_type`.
  """
  @callback upload(key :: String.t(), path :: Path.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc """
  An object is arriving at `serving_key`. Returns the key to write the bytes to.

  Called once per object, before the bytes are written — at presign time for a
  browser upload, immediately before the PUT for a server-side one. This is the
  host's chance to record the object, and to say where it wants the bytes. A
  host that would rather not work on an object until something references it can
  wait for `c:object_referenced/3` — a picked file is not a saved one.

  `opts` carries what the surface knows, all optional:

    * `:accepts` — the field's allowed media classes (`[:image, :video]`)
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

  Optional; left out, every object is `:ready`.
  """
  @callback object_states(keys :: [key()]) :: %{optional(key()) => state()}

  @doc """
  A saved record now references `keys`.

  Called after a record carrying attachments is created or updated, so the host
  can tell an object that was attached to something from one whose form was
  abandoned. With `auto_upload: true` the bytes are in storage from the moment a
  file is picked, so this is the only signal that anything came back for them.

  Optional; left out, the reference is `:ok` and nothing is recorded.
  """
  @callback object_referenced(keys :: [key()], resource :: module(), resource_id :: term()) ::
              :ok | {:error, term()}

  @optional_callbacks object_arriving: 2, object_states: 1, object_referenced: 3

  @doc """
  Returns `{:ok, url}` for the given attachment value, or `:processing` /
  `:rejected` when the host is not serving that object.

  Options:

    * `:states` — a `%{key => state}` map from `states_for/1`, treated as
      authoritative: a key absent from it is `:ready`. Pass this when
      rendering more than one attachment; without it each call costs its
      own lookup.
    * `:variant` — which rendition to serve. Only `:original` (the
      default) exists today; anything else raises. The argument is here
      so a host that later derives renditions has somewhere to ask for
      one without every call site changing shape.
    * `:expires_in` — TTL in seconds for signed URLs. Defaults to
      `#{@default_ttl_seconds}` (1 hour). Ignored for `public/*` keys.
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
  """
  @spec states_for([Value.t() | String.t()]) :: %{optional(key()) => state()}
  def states_for(values) do
    values
    |> Enum.flat_map(fn
      %Value{key: key} when is_binary(key) -> [key]
      key when is_binary(key) -> [key]
      _other -> []
    end)
    |> Enum.uniq()
    |> object_states()
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

  defp keys_in(%Value{key: key}) when is_binary(key), do: [key]
  defp keys_in(values) when is_list(values), do: Enum.flat_map(values, &keys_in/1)

  # Everything else a struct-valued attribute can hold — a `DateTime`, an
  # `Ash.NotLoaded`, a `Money` — is not an Ash resource and stops the walk here.
  defp keys_in(%resource{} = embedded) do
    if Ash.Resource.Info.resource?(resource) and Ash.Resource.Info.embedded?(resource),
      do: attachment_keys(embedded),
      else: []
  end

  defp keys_in(_value), do: []

  # A prefetched map is the whole batch, so a missing key means "no state
  # held" rather than "not fetched yet".
  defp state(key, opts) do
    case Keyword.fetch(opts, :states) do
      {:ok, states} -> Map.get(states, key, :ready)
      :error -> Map.get(object_states([key]), key, :ready)
    end
  end

  defp validate_variant!(:original), do: :ok

  defp validate_variant!(variant) do
    raise ArgumentError,
          "unknown attachment variant #{inspect(variant)}; only :original is served today"
  end

  defp serving_url(%Value{key: "public/" <> _ = key}, _opts), do: impl().public_url(key)

  defp serving_url(%Value{key: key}, opts),
    do: presigned_get_url(key, Keyword.take(opts, [:expires_in]))

  @doc """
  Returns a presigned `PUT` URL for uploading to the given key. Used by
  the upload pipeline; centralized here so the same hostname / signing
  conventions as `url_for/2` apply. See the `c:presigned_put_url/2`
  callback for the options.
  """
  def presigned_put_url(key, opts \\ []) when is_binary(key),
    do: impl().presigned_put_url(key, opts)

  @doc """
  Returns a presigned `GET` URL for an arbitrary key. Use this for
  server-generated objects (e.g. a report uploaded with `upload/3`) where
  there is no `Value` struct to hand to `url_for/2`. See the
  `c:presigned_get_url/2` callback for the options.
  """
  def presigned_get_url(key, opts \\ []) when is_binary(key),
    do: impl().presigned_get_url(key, opts)

  @doc """
  Streams a local file up to `key` (server-side `PUT`). The caller already
  holds the bytes — use this when the object is generated server-side
  rather than uploaded by the browser via `presigned_put_url/2`.
  """
  def upload(key, path, opts \\ []) when is_binary(key) and is_binary(path),
    do: impl().upload(key, path, opts)

  @doc "See `c:object_arriving/2`. The passthrough answer is `serving_key` itself."
  def object_arriving(serving_key, opts \\ []),
    do: lifecycle(:object_arriving, [serving_key, opts], {:ok, serving_key})

  @doc "See `c:object_states/1`. The passthrough answer withholds nothing."
  def object_states([]), do: %{}
  def object_states(keys), do: lifecycle(:object_states, [keys], %{})

  @doc "See `c:object_referenced/3`. The passthrough answer is `:ok`."
  def object_referenced([], _resource, _resource_id), do: :ok

  def object_referenced(keys, resource, resource_id),
    do: lifecycle(:object_referenced, [keys, resource, resource_id], :ok)

  defp impl, do: AshQuick.Config.storage()

  # The lifecycle callbacks are optional, so a storage module that leaves one
  # out is answered for it here rather than made to say "nothing" three times.
  defp lifecycle(callback, args, passthrough) do
    impl = impl()

    if Code.ensure_loaded?(impl) and function_exported?(impl, callback, length(args)),
      do: apply(impl, callback, args),
      else: passthrough
  end

  defmodule S3 do
    @moduledoc """
    The default `AshQuick.Storage` implementation: plain ExAws against
    `AshQuick.Config.s3_bucket/0` and `AshQuick.Config.s3_host/0`.

    Each callback has a head that takes the bucket explicitly. They are for
    a host whose own object-store seam owns the bucket: it points
    `:storage` at itself and calls these with its own bucket, so signing
    and key encoding are stated once rather than restated per host.
    """
    @behaviour AshQuick.Storage

    @default_ttl_seconds 3600

    @impl true
    def public_url(key), do: public_url(bucket(), AshQuick.Config.s3_host(), key)

    @doc "`c:AshQuick.Storage.public_url/1` against an explicit bucket and host."
    def public_url(bucket, host, key), do: "https://#{bucket}.#{host}/#{encode_key(key)}"

    @impl true
    def presigned_put_url(key, opts), do: presigned_put_url(bucket(), key, opts)

    @doc "`c:AshQuick.Storage.presigned_put_url/2` against an explicit bucket."
    def presigned_put_url(bucket, key, opts) do
      presigned_url(bucket, :put, key,
        expires_in: ttl(opts),
        query_params: maybe_param([], "Content-Type", Keyword.get(opts, :content_type)),
        headers: maybe_param([], "content-length", Keyword.get(opts, :content_length))
      )
    end

    @impl true
    def presigned_get_url(key, opts), do: presigned_get_url(bucket(), key, opts)

    @doc "`c:AshQuick.Storage.presigned_get_url/2` against an explicit bucket."
    def presigned_get_url(bucket, key, opts) do
      presigned_url(bucket, :get, key,
        expires_in: ttl(opts),
        query_params: Keyword.get(opts, :query_params, [])
      )
    end

    @impl true
    def upload(key, path, opts), do: upload(bucket(), key, path, opts)

    @doc "`c:AshQuick.Storage.upload/3` against an explicit bucket."
    def upload(bucket, key, path, opts) do
      s3_opts =
        case Keyword.get(opts, :content_type) do
          nil -> []
          content_type -> [content_type: content_type]
        end

      path
      |> ExAws.S3.Upload.stream_file()
      |> ExAws.S3.upload(bucket, key, s3_opts)
      |> ExAws.request()
      |> case do
        {:ok, _} -> :ok
        {:error, term} -> {:error, term}
      end
    end

    defp bucket, do: AshQuick.Config.s3_bucket()

    defp ttl(opts), do: Keyword.get(opts, :expires_in, @default_ttl_seconds)

    defp maybe_param(params, _name, nil), do: params
    defp maybe_param(params, name, value), do: [{name, to_string(value)} | params]

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
