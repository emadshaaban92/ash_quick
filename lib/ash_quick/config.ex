defmodule AshQuick.Config do
  @moduledoc """
  Reads AshQuick library configuration.

  Configuration lives under the `:ash_quick` key. For example:

      config :ash_quick,
        nav: MyAppWeb.Nav,
        timezone: "America/New_York"

  ## Configuration options

  * `:nav` — A module using `AshQuick.Nav`: the labels, icons and groups the
    router cannot supply, plus the entries that are not QuickViews. The router
    the QuickViews are discovered from and the access control every rendering
    filters through are both declared on it. When `nil`, there is no
    navigation to render.

  * `:check` — Options for `mix ash_quick.check`. Only `:exempt` is read:
    `[exempt: [tileless_route: ["/"]]]` keeps a divergence the application has
    decided to live with out of the report. See `AshQuick.Check`.

  * `:timezone` — The timezone the formatters in this module display dates and
    timestamps in (e.g. `"America/New_York"`). Defaults to `"Etc/UTC"`. A scope
    can name a timezone field of its own, but only `AshQuick.Scope.timezone/1`
    reads it — `format_datetime/1` and friends are application-wide.

  * `:locale` — The default locale. Defaults to `"en"`. A scope's own locale is
    likewise reached through `AshQuick.Scope.locale/1` alone.

  * `:storage` — A module implementing `AshQuick.Storage` — everything
    that needs a bucket, a host or credentials, plus the optional lifecycle
    callbacks that route an arriving upload somewhere of the host's choosing
    and withhold objects that are not servable yet. Defaults to
    `AshQuick.Storage.S3`, which implements no lifecycle: bytes go straight to
    their serving key and every object is servable. A host with its own
    object-store client points this at it, and `:s3_bucket` / `:s3_host`
    below go unread.

  * `:pdf_renderer` — A module implementing `AshQuick.PdfRenderer`, which
    turns a print template's output into the PDF an action's print delivers.
    Defaults to `AshQuick.PdfRenderer.ChromicPDF`. A test suite with no Chrome
    names one that hands back the template's HTML, to read what a print says.

  * `:s3_bucket` — The S3 bucket name `AshQuick.Storage.S3` uses for
    uploads (image uploads, exports, prints).

  * `:s3_host` — The S3-compatible host `AshQuick.Storage.S3` constructs
    public URLs against (e.g. `"s3.amazonaws.com"`,
    `"storage.googleapis.com"`). Defaults to `"s3.amazonaws.com"`.

  * `:error_translator` — A `{Module, :function}` tuple for translating
    changeset error tuples. The function receives `{msg, opts}` and must
    return a string. When `nil`, AshQuick uses simple string interpolation.
    Example: `{MyAppWeb.CoreComponents, :translate_error}`.

  * `:gettext` — The host's Gettext backend (e.g. `MyAppWeb.Gettext`). Every
    string AshQuick draws, its own and the labels it draws (field and action
    names, `label:` options, nav entries and groups, page titles and the values
    of an enum or a `one_of` atom), is looked up there in the `ash_quick`
    domain, in that backend's locale. `mix ash_quick.gen.gettext` writes the
    template. When `nil`, everything is drawn in English. See
    `AshQuick.Gettext` and `AshQuick.Labels`.

  * `:endpoint` — The host's `Phoenix.Endpoint`. AshQuick publishes resource
    notifications through it, signs impersonation tokens with its secret, and
    reads the PubSub server `AshQuick.BrowserSessionPresence` rides on off its
    configuration. Required for liveness; without it a resource carrying the
    `AshQuick` extension publishes nothing. Read at compile time (resources
    bake their publications from it), so it belongs in `config.exs`, not
    `runtime.exs`.

  * `:refetch_window` — The default minimum time (in ms) between QuickView
    refetches, including those caused by a PubSub notification. Defaults to
    5 seconds.

  * `:actor_resource` — The resource a record's `inserted_by` / `updated_by`
    relationships point at, and that AshQuick loads an actor through when it
    has to name who wrote a record. `nil` when the host stamps no actor. Its
    domain is read off the resource, so it is not configured separately. Read
    at compile time (resources bake those relationships from it), so it belongs
    in `config.exs`, not `runtime.exs`.

  * `:audit_resource` — The resource AshQuick records audited writes in, for
    every resource that does not name a store of its own. Auditing is on by
    default and has no fallback sink, so a resource with no store resolvable
    from here refuses to compile.

  * `:impersonation_max_age` — How long a minted token stays resolvable, in
    seconds. Defaults to twelve hours: long enough to drive a full flow without
    re-picking the person, short enough that a forgotten tab does not stay
    somebody else indefinitely.

  * `:actor_assign` — The assign a mount's authenticated actor arrives in, read
    by `AshQuick.LiveView.Impersonation` before the host's scope exists.
    Defaults to `:current_user`.

  * `:client_ip` — Where `AshQuick.ClientIp` reads the address an audit row and
    a browser session record, for a LiveView and a controller alike. Read on
    every request, so it may be set in `runtime.exs`. One of:

      * `:peer` — the address of whatever opened the connection. The default.
      * `{:header, name}` — the last entry of the last `name` header, falling
        back to the peer address when it is missing or not an IP. `name` must
        start with `x-`: Phoenix passes a LiveView no other headers.
      * `{module, function, args}` — `apply(module, function, [info | args])`,
        where `info` is `%{peer_data: ..., x_headers: ...}`. It returns an IP
        address string or `nil`.

    **Name a header only when nothing but your proxy can reach the app**:
    whoever can reach it can set the header to any address they like. See
    `client_ip/0`, and assert `AshQuick.ClientIp.config_violations/1` is empty
    in a test.

  * `:versioning_ignored_attributes` / `:versioning_ignored_relationships` —
    **Additions** to what an update may change without bumping the optimistic
    lock, for a host carrying bookkeeping of its own beyond the four AshQuick
    owns. The four themselves are not listed here: they are derived per
    resource from its `bookkeeping` declaration by
    `versioning_ignored_attributes/1` and `versioning_ignored_relationships/1`.
    Both default to `[]`.
  """

  @otp_app :ash_quick

  @doc """
  Returns the configured `AshQuick.Nav` module, or `nil` if not configured.
  """
  def nav do
    get(:nav)
  end

  @doc """
  The divergences `mix ash_quick.check` is told not to report, as
  `[check_name: [subject]]`.

  See `AshQuick.Check` for what a subject is per check, and why an accepted
  divergence is recorded here rather than passed as a flag.
  """
  def check_exemptions do
    :check |> get([]) |> Keyword.get(:exempt, [])
  end

  @doc """
  Returns the configured default timezone. Defaults to `"Etc/UTC"`.
  """
  def timezone do
    get(:timezone, "Etc/UTC")
  end

  @doc """
  Returns the configured default locale. Defaults to `"en"`.

  The application-wide fallback for a scope that states no locale of its own —
  see `AshQuick.Scope.locale/1`.
  """
  def locale do
    get(:locale, "en")
  end

  @doc """
  Returns the host's endpoint, or `nil` when none is configured.

  The one module AshQuick borrows from the host for everything an endpoint
  does: `AshQuick.PubSub.Transformer` publishes a resource's notifications
  through it, `AshQuick.Impersonation.Token` signs with its secret, and
  `AshQuick.BrowserSessionPresence` rides the PubSub server its configuration
  names. A resource carrying the `AshQuick` extension without this configured
  gets no liveness.

  Two readers are compile time: the transformer bakes a resource's
  publications from this, and `AshQuick.LiveView.Liveness.verify_publishable!/2`
  checks a QuickView against it. So a value that only reaches the application at
  runtime — declared in `runtime.exs`, which a release loads long after the
  resources were compiled — leaves every resource carrying the publications it
  built from whatever it saw instead, and nothing says so: the pages are simply
  dead. Hence the `compile_env` read below, which pins what was compiled against
  so a release refuses to boot when the two disagree. Configure this in
  `config.exs`. The lookup itself stays at runtime, like every other option here.
  """
  @endpoint Application.compile_env(@otp_app, :endpoint)

  def endpoint do
    get(:endpoint, @endpoint)
  end

  @doc """
  Returns the default minimum time (in ms) between QuickView refetches.

  Defaults to 5 seconds. A view overrides it with
  `liveness_options: [refetch_window: ...]`.
  """
  def refetch_window do
    get(:refetch_window, :timer.seconds(5))
  end

  @doc """
  Where the client's IP address is read from. Defaults to `:peer`.

  What `AshQuick.ClientIp` resolves on every request, through
  `AshQuick.LiveView.Mount.connect_ip/1` for a LiveView and
  `AshQuick.ClientIp.from_conn/1` for a controller, and so the address audit
  rows and browser sessions record. Read then rather than at compile time, so
  `runtime.exs` may set it. It accepts exactly three forms:

    * `:peer` — the `:peer_data` address, or `nil` when there is none.

    * `{:header, name}` — the header `name`, matched lowercased. When it appears
      more than once the last occurrence is read, and of a comma-separated value
      the last entry. A header that is missing, empty or not an IP falls back to
      the peer address. `name` must start with `x-`, since Phoenix's
      `:x_headers` connect info holds nothing else; any other name raises
      `ArgumentError`, because it could never be read.

    * `{module, function, args}` — called as
      `apply(module, function, [info | args])`, where `info` is
      `%{peer_data: ..., x_headers: ...}`, shaped as
      `Phoenix.LiveView.get_connect_info/2` returns them. It runs on the
      disconnected render too, where both are read from the request, and either
      is `nil` only when the endpoint does not offer it. It returns
      `nil` or a string `:inet.parse_address/1` accepts, formatted the same way
      as the other forms; anything else raises `ArgumentError`. `nil` means no
      address, and is not replaced by the peer's.

  Any other value raises `ArgumentError` on connect. That happens only once
  something connects, so check the value in a test with
  `AshQuick.ClientIp.config_violations/1`.

  **Name a header only when nothing but your proxy can reach the app.** Whoever
  can reach the app can set the header to any address they like, and that is
  what their audit rows then record. Resolving the client behind whatever sits
  in front of the proxy (a WAF, a CDN) is the proxy's job:

      config :ash_quick, client_ip: {:header, "x-real-ip"}

  with the proxy overwriting `X-Real-IP` with the client it resolved. See
  `AshQuick.LiveView.Mount`.
  """
  def client_ip do
    get(:client_ip, :peer)
  end

  @doc """
  Formats a `DateTime` or `NaiveDateTime` for display.

  Shifts a `DateTime` to the configured timezone; a `NaiveDateTime` names no
  zone, so it is formatted as it is. Formats with `Localize.DateTime` in the
  reader's locale (`AshQuick.Locale.current/0`) when Localize is loaded;
  otherwise, or for a locale Localize does not know, falls back to
  `Calendar.strftime/2`.
  """
  def format_datetime(nil), do: ""

  def format_datetime(%DateTime{} = value) do
    value |> DateTime.shift_zone!(timezone()) |> localize_datetime()
  end

  def format_datetime(%NaiveDateTime{} = value), do: localize_datetime(value)

  defp localize_datetime(value) do
    localized(Localize.DateTime, value, [], fn ->
      Calendar.strftime(value, "%Y-%m-%d %H:%M:%S")
    end)
  end

  @doc """
  Formats a `Time`, or the time-of-day part of a `DateTime`, for display.

  Shifts a `DateTime` to the configured timezone; a `Time` names no zone, so
  it is formatted as it is. Defaults to a short time (`"9:32 PM"`); pass
  `format: :medium` for second precision.
  """
  def format_time(value, opts \\ [])

  def format_time(nil, _opts), do: ""

  def format_time(%DateTime{} = value, opts) do
    value |> DateTime.shift_zone!(timezone()) |> localize_time(opts)
  end

  def format_time(%Time{} = value, opts), do: localize_time(value, opts)

  defp localize_time(value, opts) do
    format = Keyword.get(opts, :format, :short)

    localized(Localize.Time, value, [format: format], fn ->
      Calendar.strftime(value, strftime_time_format(format))
    end)
  end

  defp strftime_time_format(:short), do: "%H:%M"
  defp strftime_time_format(_), do: "%H:%M:%S"

  @doc """
  Formats a `Date` for display.

  Uses `Localize.Date` in the reader's locale when Localize is loaded;
  otherwise, or for a locale Localize does not know, falls back to
  `Calendar.strftime/2`.
  """
  def format_date(nil), do: ""

  def format_date(%Date{} = value) do
    localized(Localize.Date, value, [], fn -> Calendar.strftime(value, "%Y-%m-%d") end)
  end

  @doc """
  Formats a `Money` for display, in the reader's locale
  (`AshQuick.Locale.current/0`): its digits, separators and where the
  currency goes. A locale Localize cannot parse falls back to `Money`'s own
  `to_string/1`.
  """
  def format_money(%{__struct__: Money} = value) do
    localized(Money, value, [], fn -> to_string(value) end)
  end

  # Localize keeps a locale of its own that nothing sets, so the reader's is
  # passed. A locale Localize has no data for falls back inside Localize; one it
  # cannot parse at all is an error, which reads as no Localize.
  defp localized(module, value, opts, fallback) do
    with true <- Code.ensure_loaded?(module),
         {:ok, string} <- module.to_string(value, [locale: AshQuick.Locale.current()] ++ opts) do
      string
    else
      _no_localize -> fallback.()
    end
  end

  @doc """
  Shifts `DateTime.utc_now()` to the configured timezone.

  Useful for generating timezone-aware file names for exports and prints.
  """
  def now_in_timezone do
    DateTime.utc_now() |> DateTime.shift_zone!(timezone())
  end

  @doc """
  Returns the configured `AshQuick.Storage` implementation.

  Defaults to `AshQuick.Storage.S3`, which implements none of the optional
  lifecycle callbacks — bytes go straight to their serving key and every
  object is servable.
  """
  def storage do
    get(:storage, AshQuick.Storage.S3)
  end

  @doc """
  Returns the configured `AshQuick.PdfRenderer`, `AshQuick.PdfRenderer.ChromicPDF`
  by default.
  """
  def pdf_renderer do
    get(:pdf_renderer, AshQuick.PdfRenderer.ChromicPDF)
  end

  @doc """
  Returns the configured S3 bucket name.
  """
  def s3_bucket do
    get(:s3_bucket)
  end

  @doc """
  Returns the configured S3 host. Defaults to `"s3.amazonaws.com"`.
  """
  def s3_host do
    get(:s3_host, "s3.amazonaws.com")
  end

  @doc """
  Returns the host's Gettext backend AshQuick translates through, or `nil` for
  none.
  """
  def gettext do
    case get(:gettext) do
      AshQuick.Gettext ->
        # It forwards every lookup to this backend, so it would forward to
        # itself until the stack gave out.
        raise ArgumentError,
              "config :ash_quick, gettext: names the host's own Gettext backend " <>
                "(e.g. MyAppWeb.Gettext), not AshQuick.Gettext, which forwards to it"

      backend ->
        backend
    end
  end

  @doc """
  Returns the configured error translator, or `nil` for the default.

  When set, should be a `{Module, :function}` tuple.
  """
  def error_translator do
    get(:error_translator)
  end

  @doc """
  The actor resource `belongs_to :inserted_by` and `belongs_to :updated_by`
  point at, or `nil` when the host configures none.

  What AshQuick loads and renders an actor through when it has to name who
  wrote a record. The generated relationship crosses domains, so it needs the
  destination's domain too — `AshQuick.Bookkeeping.Transformer` reads that off
  this resource rather than taking it as a second config key that could name a
  domain the resource does not belong to.

  Compile time and runtime both read this, and they have to agree.
  `AshQuick.Bookkeeping.Transformer` bakes each resource's `inserted_by` /
  `updated_by` relationships — destination and domain — from what it sees while
  the resource compiles, and `AshQuick.LiveView.DetailsUtils` builds its strict
  load from what it sees on the request. A value that only reaches the
  application at runtime leaves the two naming different resources: the load
  asks for the label field of one across a relationship to the other, and the
  details page fails on a field name rather than on the config that chose it.
  Hence the `compile_env` read below, so a release refuses to boot when they
  disagree. Configure this in `config.exs`.
  """
  @actor_resource Application.compile_env(@otp_app, :actor_resource)

  def actor_resource do
    get(:actor_resource, @actor_resource)
  end

  @doc """
  The attribute names an update to `resource` may change without bumping its
  optimistic lock.

  The resource's own bookkeeping columns — its timestamps and the source
  attributes behind its actor relationships — plus anything the host adds under
  `:versioning_ignored_attributes`. An update touching only these is a no-op as
  far as the lock is concerned; see `AshQuick.Versioning.Lock`.

  Derived per resource rather than fixed globally, because a global list is a
  claim about every resource at once: it silently ignored `:updated_by_id` on
  resources that have no such column, and would have gone on ignoring
  `:created_at` on a resource that named its timestamp something else.
  `AshQuick.Bookkeeping.Verifier` is what makes the derived answer exact — a
  bookkeeping column left undeclared would drop out of this list and start
  bumping the lock on writes that used to be no-ops.

  The config key remains as an **addition** for a host with bookkeeping of its
  own (a `:last_synced_at`, say) — it no longer carries the four AshQuick owns.
  """
  def versioning_ignored_attributes(resource) do
    AshQuick.Info.timestamp_fields(resource) ++
      AshQuick.Info.actor_attributes(resource) ++
      get(:versioning_ignored_attributes, [])
  end

  @doc """
  The relationship names an update to `resource` may change without bumping its
  optimistic lock.

  The actor relationships it stamps, plus anything the host adds under
  `:versioning_ignored_relationships`. The attribute half is
  `versioning_ignored_attributes/1` — a changeset carries the two separately,
  so the lock has to drop from both.
  """
  def versioning_ignored_relationships(resource) do
    AshQuick.Info.actor_fields(resource) ++ get(:versioning_ignored_relationships, [])
  end

  @doc """
  The resource audited writes are recorded in, or `nil` when the host
  configured none.

  The app-wide default behind `audit do store ... end`, generated by
  `mix igniter.install ash_quick`. Read per write rather than baked into the
  resources, since nothing about a resource's compiled form depends on where
  its changes are recorded — but `AshQuick.Audit.Verifier` reads it while they
  compile to settle that there *is* one, so it belongs in `config.exs` rather
  than `runtime.exs`.
  """
  def audit_resource do
    get(:audit_resource)
  end

  @doc """
  How long an impersonation token stays resolvable, in seconds.

  A working day by default.
  """
  def impersonation_max_age do
    get(:impersonation_max_age, 60 * 60 * 12)
  end

  @doc """
  The assign a mount's authenticated actor arrives in. Defaults to
  `:current_user`.

  `AshQuick.LiveView.Impersonation` runs before the host builds its scope, so
  the scope cannot be what it reads the actor from. It reads this assign
  instead, which whatever put the session on the socket has already set —
  `:current_user` is AshAuthentication's name for it, and the default here for
  that reason rather than because it is AshQuick's.
  """
  def actor_assign do
    get(:actor_assign, :current_user)
  end

  @doc """
  Returns `true` if Excel/CSV export dependencies are available.

  Checks for `Exceed` (XLSX) and `NimbleCSV` (CSV) at runtime.
  """
  def exports_enabled? do
    Code.ensure_loaded?(Exceed) and Code.ensure_loaded?(NimbleCSV)
  end

  @doc """
  Returns `true` if a print can be rendered: the host names its own
  `:pdf_renderer`, or has `ChromicPDF` for the default one.
  """
  def print_enabled? do
    pdf_renderer() != AshQuick.PdfRenderer.ChromicPDF or Code.ensure_loaded?(ChromicPDF)
  end

  defp get(key, default \\ nil) do
    Application.get_env(@otp_app, key, default)
  end
end
