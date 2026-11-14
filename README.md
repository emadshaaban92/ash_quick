# AshQuick

Declarative CRUD LiveViews for [Ash](https://hexdocs.pm/ash) resources.

A resource gains `extensions: [AshQuick]`, a module declares
`use AshQuick.LiveView.QuickView`, and the router mounts it with
`quick_view/3` — list, details, create and update, with filtering, sorting,
pagination, relationship dropdowns, Excel/CSV export, printing, optimistic
locking, an audit trail and live updates.

Everything the library needs from the application around it is a behaviour or a
configuration key: the actor and tenant (`AshQuick.Scope`), object storage
(`AshQuick.Storage`), route access (`AshQuick.AccessControl`), navigation
(`AshQuick.Nav`), print templates (`AshQuick.PrintTemplate`) and read-only
field checks (`AshQuick.ReadOnlyFields.Check`). An action prints by
carrying `AshQuick.Print`.

The moduledocs are the reference. This is the order to read them in.

## Installation

```console
$ mix igniter.install ash_quick
```

That writes everything the rest of this section describes: the configuration
block, a placeholder for Tower's reporter, the audit store with its domain and migration, a starter nav and access
control, the router import, the formatter entries, the supervised presence, and
the Tailwind source line. It states the one step it will not guess at — the
client half of `app.js`, which is a rewrite rather than a line to append — and
running it again changes only what is missing.

The rest of this section is what it does and why, for reading the diff or wiring
it by hand.

```elixir
def deps do
  [{:ash_quick, github: "emadshaaban92/ash_quick"}]
end
```

On AshPostgres, AshQuick supports PostgreSQL 17 or later, and the repo should
say so, because AshPostgres writes SQL for the version the repo declares rather
than the one it connects to:

```elixir
# lib/my_app/repo.ex
def min_pg_version, do: %Version{major: 17, minor: 0, patch: 0}
```

Declaring less turns off what versioning relies on for `Ash.update_many/4`: the
single `MERGE` that locks each loaded record. Below it, each record falls back
to a bulk write that needs `strategy: [..., :stream]`.

### Configuration

Configuration lives under the `:ash_quick` key in `config/config.exs` — **not
`runtime.exs`**:

```elixir
config :ash_quick,
  endpoint: MyAppWeb.Endpoint,
  actor_resource: MyApp.Accounts.User,
  audit_resource: MyApp.AuditLog,
  nav: MyAppWeb.Nav,
  storage: MyApp.Uploads.ObjectStore,
  gettext: MyAppWeb.Gettext,
  error_translator: {MyAppWeb.CoreComponents, :translate_error},
  timezone: "Etc/UTC"
```

`:endpoint` and `:actor_resource` are read with `Application.compile_env/2`,
because resources bake them in while they compile: the endpoint becomes each
resource's PubSub publications, the actor resource becomes its `inserted_by` /
`updated_by` relationships. Declared in `runtime.exs`, a release would load
them long after the resources were built against `nil`, and nothing would say
so — the pages would simply be dead and the columns empty. `compile_env` turns
that into a refusal to boot. Everything else is read at runtime and may move.

`AshQuick.Config` documents every key, including the S3 ones,
`:refetch_window` and `:impersonation_max_age`.

`:error_translator` is the function your forms translate errors with. AshQuick
puts Ash's error messages through it everywhere it shows one, in a flash as well
as next to an input. Ash marks its own messages for translation; to have them in
the catalogue a Phoenix `translate_error/1` reads, run:

```bash
mix ash.gen.gettext --domain errors
mix gettext.merge priv/gettext
```

A form shows a field error under its input. An error with no input to show it
(a field set by a change, or not accepted) is flashed with its field in front,
set off by a colon: `Ref: must match …`. Errors that name no field are flashed
as written. A custom form template (`action_<name>.html.heex`) is assumed to
render an input for every field the action offers; an error on a field it
leaves out shows nowhere.

A run a policy refuses shows that policy's `error_message` when it has one, and
"You don't have permission to do that." when it has none; that sentence, like
AshQuick's other flashes, is one of AshQuick's own messages (see below). The
policy's message is a msgid like Ash's own, so it goes through
`:error_translator` too: add it to your `errors` catalogue. Only the message is
shown, never the policy breakdown.
An `error_message` function that returns an exception of its own replaces the
policy error, so the flash shows the fixed sentence instead. A form the actor
may not run at all, reached by its URL, opens on an "Access Forbidden" panel,
which says the refusing policy's `error_message` too when it has one. Menus
and buttons leave out an action the actor may not run.

Field policies decide what a page shows: a column hidden on every record is
left out, and a value hidden on one record reads as a muted dash. An update
form never draws, prefills or sends a field its reader may not see on the
record it updates, nor an argument named like one, so a save from the form
leaves that field as it is. An update whose every input is hidden that way
opens on the forbidden panel. A bulk form leaves out a field hidden from the
actor on any record, since its value would go to all of them.

Field policies govern reading. They don't stop a write sent another way: the
same action can run through an API, a script or a hand-sent event. To refuse
writes to a field, add an action policy with `changing_attributes/1`:

```elixir
policy [action_type(:update), changing_attributes([:salary])] do
  authorize_if actor_attribute_equals(:role, :admin)
end
```

A save the policy refuses flashes its `error_message`, as above.

#### Translating

`:gettext` names your Gettext backend, and AshQuick translates everything else
it draws there, in the `ash_quick` domain and in that backend's locale: its own
buttons, flashes and empty states, and the labels it draws. A label is English
wherever it comes from: a field or action name humanized, a `label:` option, a
`new_action_label`, a saved filter's label, a custom bulk item's title, a nav
entry or group, a page title, an enum's or a `one_of` atom's value. Many are
fixed when a QuickView compiles, so AshQuick translates each where it draws it,
on the process that renders, where the reader's locale is set. Set the locale
however you set it for your own pages, process-wide or on your backend.
Without `:gettext`, AshQuick draws English.

An export runs in a task of its own, which inherits no locale, so it is
written in the scope's (`AshQuick.Scope.locale/1`): the field
`use AshQuick.Scope, locale: :locale` names, or `config :ash_quick, locale:`
(`"en"`) when the scope names no field or it holds `nil`. Set the page's
locale from the scope, in the scope stage, and the two read alike:

```elixir
locale = AshQuick.Scope.locale(scope)
Gettext.put_locale(MyAppWeb.Gettext, locale)
```

The page runs the way the locale writes: right to left for Arabic, Hebrew,
Persian and the other right-to-left scripts. AshQuick's markup uses logical
CSS properties, and its arrows and chevrons turn with the page, so `dir` on
`<html>` is the only switch. Set it, and `lang`, in your root layout:

```heex
<html lang={AshQuick.Locale.current()} dir={AshQuick.Locale.direction()}>
```

The dead render resolves the locale before a tab says who it is, so a tab that
turns out to be impersonating someone has the real user's `lang` and `dir`.
Push the right ones from the connected mount, and `attachAshQuick` (see
[Assets](#assets)) applies them to `<html>`:

```elixir
push_event(socket, "locale", %{
  lang: locale,
  dir: AshQuick.Locale.direction(locale)
})
```

Labels are not `gettext` call sites, so `mix gettext.extract` cannot find them.
`mix ash_quick.gen.gettext` writes `priv/gettext/ash_quick.pot` with AshQuick's
own messages and every label your nav and QuickViews draw, read off them along
with the resources they reach:

```bash
mix ash_quick.gen.gettext --locale ar
mix gettext.merge priv/gettext
```

`--locale ar` copies the Arabic translation AshQuick ships, as a starting point;
copied once, it is yours to edit. Run the task again when you add a field, an
action or a nav entry, and `mix ash_quick.gen.gettext --check` in CI fails
until you do. A label the task cannot read, such as the title of a bulk item a
function builds, is marked where you write it, and `mix gettext.extract` adds
it to the same template, which the task keeps:

```elixir
%{title: dgettext_noop("ash_quick", "Discount 10%"), func: JS.push("discount")}
```

A humanized name is only a default: `vat_number` reads "Vat Number", and a
locale code `ar` reads "Ar". Reword one where it is drawn, or in the catalogue:

* a `label` in the resource's `ash_quick` block, for a field, relationship,
  action, action argument or value, on every page that names it: list
  columns, details rows, form inputs, filters, row and bulk actions, error
  messages, and custom templates labelling it through `AshQuick.Labels`
  (`name/2`, `field/2`, `value/3`, given the resource). The task writes the
  declared label as the msgid, beside the humanized name, so a translator
  works from the English your readers see:

  ```elixir
  ash_quick do
    labels do
      label :vat_number, "VAT number"
      label :issue_bill_of_sale, "Issue Bill of Sale"
      label :status, :paid_off, "Paid off in full"
    end
  end
  ```

  A name or value the resource does not have does not compile;
* a `label:` on the QuickView's field, `{:vat_number, label: "VAT number"}`,
  for that page, over the resource's;
* a `label:` on an `Ash.Type.Enum`'s value (`ar: [label: "العربية"]`), for
  that value everywhere it shows, unless the resource labels it;
* a translation, for every page that draws the label, English included: give
  `"Vat Number"` a `msgstr` of `"VAT number"` in
  `priv/gettext/en/LC_MESSAGES/ash_quick.po`
  (`mix gettext.merge priv/gettext --locale en` creates it).

One English label has one translation, wherever it is drawn, which is wrong
for a language whose words agree with the noun they describe: in Arabic a
cancelled loan is ملغى and a cancelled approval ملغاة. So a label of a
resource is looked up under that resource's context first, its short name for
a field, action or argument (`msgctxt "loan"`) and that and the field's name
for a value (`msgctxt "loan.status"`), and its context-free translation after.
Translate the context-free entry as usual, and add a contexted one only where
your language needs it:

```po
msgid "Cancelled"
msgstr "ملغاة"

msgctxt "loan.status"
msgid "Cancelled"
msgstr "ملغى"
```

`mix ash_quick.gen.gettext` keeps a contexted entry you add by hand: the
template lists each one some locale's `ash_quick.po` translates, so
`mix gettext.merge` does not delete it as obsolete (an entry whose label no
page draws under that context any more is left out, and does become
obsolete). `mix ash_quick.gen.gettext --contexts` writes every contexted
variant into the template, so a translator can see where each label is drawn;
leave the ones your language does not need empty. Two resources sharing a
short name share their contexts. Labels with no resource behind them, a nav
entry or a page title, have none.

The template being complete does not make a locale's translation complete: an
entry left with an empty `msgstr` is drawn in English. To hear about those in
dev, override your backend's `handle_missing_translation/5`, which Gettext calls
for every message a locale has no translation for, AshQuick's included. A
label is reported once, under its context, and only when neither its
contexted nor its context-free entry is translated:

```elixir
# in MyAppWeb.Gettext, after `use Gettext.Backend`
require Logger

@impl Gettext.Backend
def handle_missing_translation(locale, domain, msgctxt, msgid, bindings) do
  # Once per process: a list names an enum value once, not once per row.
  key = {__MODULE__, :missing, locale, domain, msgctxt, msgid}

  # "en": the language the msgids are written in.
  if locale != "en" and !Process.get(key) do
    Process.put(key, true)
    Logger.warning("Missing #{locale} translation in #{domain}: #{inspect(msgid)}")
  end

  super(locale, domain, msgctxt, msgid, bindings)
end
```

Keep it to dev (the example app gates it on a `compile_env` flag).

A custom template that draws a resource's labels itself calls `AshQuick.Labels`
with the resource (`name/2` for a field, action or argument, `value/3` for a
value, `field/2` for a `:fields` entry, `translate/2` for an English string
and its `context/2`), so it reads the same as the pages around it.

#### Dates, times and money

Dates, times and money are formatted with Localize, when it is loaded, in the
locale your Gettext backend translates in, and a `DateTime` is shown in the
reader's zone (see [Timezones](#timezones)). Without Localize, a date reads
`2026-10-25` and a timestamp `2026-10-25 17:37:27`. Localize ships English data
alone and downloads nothing unless told to: a locale it has no data for is
formatted in English, silently. So a host lists its locales and downloads their
data, the way it fetches its deps: in development, in CI, and in the build a
release is cut from.

1. List your locales in `config/config.exs`, the ones your Gettext backend
   has. `mix localize.download_locales` loads that file alone, before anything
   is compiled, so neither `runtime.exs` nor `Gettext.known_locales/1` works
   here:

   ```elixir
   config :localize, otp_app: :my_app, supported_locales: [:en, :ar]
   ```

   `otp_app:` puts the data under your app's `priv/localize`, so a release
   carries it.

2. Keep the data out of git; it is fetched, like your deps:

   ```gitignore
   /priv/localize/
   ```

3. Download it in development, next to `deps.get` in your `setup` alias:

   ```elixir
   setup: ["deps.get", "localize.download_locales", "ecto.setup", ...]
   ```

   A locale already downloaded at Localize's version is skipped, so running it
   again is cheap.

4. Download it in CI before the tests, and cache `priv/localize` on your lock
   file and config so a run fetches nothing new:

   ```yaml
   - uses: actions/cache@v6
     with:
       path: priv/localize
       key: localize-${{ hashFiles('mix.lock', 'config/config.exs') }}
   - run: mix localize.download_locales
   ```

5. Download it in the build a release is cut from, after `mix compile` and
   before `mix release`, beside `mix assets.deploy`:

   ```dockerfile
   RUN mix compile
   RUN mix localize.download_locales
   RUN mix assets.deploy
   RUN mix release
   ```

The data lands in every release. A locale's own data is small (`ar` is about
140 KB), but the task also downloads each locale's inflection data, which for
`ar` is about 11 MB. A host that would rather not ship it sets
`allow_runtime_locale_download: true` instead, and Localize fetches a locale
the first time a reader needs it, which needs the CDN reachable from
production.

Arabic (`ar`) is written in Latin digits (`460,000.00`); a locale of
`ar-u-nu-arab` writes Arabic-Indic ones (`٤٦٠٬٠٠٠٫٠٠`).

### Error reporting

An error a page cannot explain — anything but a validation, a stale record, a
refused permission or a missing record — is shown to the person as a generic
sentence and reported through [Tower](https://hexdocs.pm/tower), which comes
with AshQuick. Tower's default reporter keeps the last 50 events in memory and
sends them nowhere, so name one that delivers them; each is a package of its
own, listed under [Tower's reporters](https://hexdocs.pm/tower/Tower.html#module-reporters):

```elixir
config :tower, reporters: [TowerSentry]
```

The installer writes `reporters: [Tower.EphemeralReporter]` here as a
placeholder, and `mix ash_quick.check` reports `unconfigured_error_reporter`
until it is replaced. `reporters: []` is taken as a decision (a test
environment, say) and is not reported.

### Assets

The `@source` line below, so QuickViews are styled, and two calls in `app.js`
further down, so each browser tab carries its own session. Without the
`@source` line every QuickView renders unstyled — the library's classes live in
its own `lib/`, which the host's Tailwind build does not scan by default.

```css
/* assets/css/app.css */
@source "../../deps/ash_quick/lib/**/*.*ex";
```

Keep the `phx-submit-loading` variant a new Phoenix app's `app.css` defines.
The action modal's spinner hangs on it, and so does every control in the modal
going still while the action runs. The installer adds it when it is missing.

```css
@custom-variant phx-submit-loading (.phx-submit-loading&, .phx-submit-loading &);
```

In `app.js`, pass the LiveSocket's options through `withAshQuick` and attach
the socket once it is built. The options themselves stay as they are:

```javascript
// assets/js/app.js
import {LiveSocket} from "phoenix_live_view"
import {withAshQuick, attachAshQuick} from "ash_quick"

const liveSocket = new LiveSocket("/live", Socket, withAshQuick({
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks},
}))
attachAshQuick(liveSocket)
```

`withAshQuick` adds what AshQuick needs to the options it is given:

- The tab's identity, which the tab mints for itself, and its impersonation
  token join the connect params on every connect. They are the unit
  `AshQuick.BrowserSessionPresence` registers and the one its `revoke/1` cuts
  an impersonation off at. `params` may be an object or a function; the host's
  own keys are kept.
- The library's colocated hooks join `hooks`. One of them keeps a checkbox, a
  radio, a select or a searchable dropdown in the action modal from being
  changed from the keyboard while the action runs.
- `S3` joins `uploaders`: the LiveView client uploader that sends a picked
  file to the presigned `PUT` `AshQuick.Storage.S3` hands out. The bucket's
  CORS rules must allow a `PUT` with a `Content-Type` header from the
  application's origin (see `AshQuick.Storage.S3`). A storage module that
  takes uploads over the socket does not use it (see `AshQuick.Storage`,
  "Browser uploads").

A hook or uploader of the host's own under the same name as one of AshQuick's
replaces it.

`attachAshQuick` listens for the events the server pushes: starting and
ending an impersonation, which reconnects every socket it was given, the `lang`
and `dir` the connected mount pushes (which the dead render could not have
known), the PDF an action carrying `AshQuick.Print` sends over the socket,
which it saves or opens the print dialog on, and the file an action marked for
download (see Files an action produces), which it saves. Its listeners are
registered once per page, however many times it is called.

`ash_quick` resolves through the esbuild `NODE_PATH` a Phoenix 1.8 app
already sets, which holds both `deps/` (where the package is) and
`Mix.Project.build_path()` (where compiling AshQuick writes its colocated
hooks). So AshQuick has to be compiled before the assets are built, as a
Phoenix 1.8 app's `assets.build` alias already does. The installer makes both
changes when `app.js` builds its socket the way Phoenix generates it.

### Router and formatter

```elixir
# lib/my_app_web/router.ex
import AshQuick.LiveView.Router
```

```elixir
# .formatter.exs
import_deps: [:ash, :ash_quick]
```

`import_deps` picks up `quick_view/3` and the DSL's `locals_without_parens`, so
the declarations format without parentheses.

If the project runs `Spark.Formatter` with a `section_order`, add `:ash_quick`
to it — sections it does not name sort last, which would push `ash_quick`
below `pub_sub` on every resource that writes one:

```elixir
config :spark, :formatter,
  "Ash.Resource": [
    section_order: [..., :actions, :policies, :ash_quick, :pub_sub]
  ]
```

### Supervision tree and mount

`AshQuick` goes in the application's tree, after the PubSub server and before
the endpoint. It starts every process the library runs under one supervisor,
`AshQuick.Supervisor`; today that is the register of signed-in tabs. Leaving it
out costs that register and nothing else: the mount warns once per navigation
and serves the page.

```elixir
children = [
  {Phoenix.PubSub, name: MyApp.PubSub},
  AshQuick,
  MyAppWeb.Endpoint
]
```

It rides the PubSub server the configured `:endpoint` names in its own
configuration. A host whose endpoint is configured under another application's
name than its own passes it: `{AshQuick, pubsub_server: MyApp.PubSub}`.

`AshQuick.LiveView.Mount` goes **first** in the live session's `on_mount`. It
resolves the tab's impersonation and reads the connection's address, and the
host's scope stage is what consumes both:

```elixir
live_session :authenticated,
  layout: {MyAppWeb.Layouts, :app},
  on_mount: [
    AshQuick.LiveView.Mount,
    {MyAppWeb.UserAuth, :assign_scope},
    {MyAppWeb.UserAuth, :require_user}
  ] do
  quick_view "/products", MyAppWeb.ProductLive.Quick
end
```

QuickView sets no layout of its own; the `live_session` does.

A QuickView has no dead render of its own: until the socket connects it draws
a spinner inside the layout, and every page, list or details, is drawn by the
connected mount. A full page load shows that spinner briefly, a navigation
within the `live_session` does not, and a browser with JavaScript off sees
nothing else. A QuickView that defines its own `render/1` draws what it likes
then, but from no data: nothing is loaded until the socket connects, so the
dead render has no list and no record to draw.

### Timezones

Lists, details pages, exports, print file names and the filter show a
timestamp in the zone of the reader's scope, `AshQuick.Scope.timezone/1`, and
`config :ash_quick, timezone:` when the scope names none. Which zone that is,
is yours to decide: one kept on the user, one for the whole organisation, or
the one the browser reports, which the LiveSocket can send beside the rest of
its params:

```javascript
params: () => ({
  _csrf_token: csrfToken,
  timezone: Intl.DateTimeFormat().resolvedOptions().timeZone
})
```

and the scope stage hands to the scope, which names the field
(`use AshQuick.Scope, timezone: :timezone`):

```elixir
timezone: Phoenix.LiveView.get_connect_params(socket)["timezone"]
```

A zone kept on the user is there on the first render as well; the browser's
arrives only once the socket connects. Any zone but UTC needs a full time zone
database, such as `tz`'s (`config :elixir, :time_zone_database,
Tz.TimeZoneDatabase`). A zone the database does not know reads as the
configured one, so a made-up one from a browser costs nothing. A page of your
own formats in the same zone by passing it:
`AshQuick.Config.format_datetime(value, AshQuick.Scope.timezone(scope))`.

`config :ash_quick, timezones:` says which zones a reader may have. Left
out, `:timezone` is the only one: every reader sees that zone, whatever their
scope names, which suits an application whose readers keep one clock. A list
(holding `:timezone`) allows those, and `:all` allows any zone the database
knows. A scope's zone outside them reads as `:timezone`, so a page never shows
a zone its forms will not take.

```elixir
config :ash_quick,
  timezone: "Europe/London",
  timezones: ["Europe/London", "Asia/Tokyo"]
```

A form's timestamp is typed into `AshQuick.Components.zoned_datetime_input/1`:
the time, and beside it the zone it is in, the reader's to begin with. With
one zone allowed there is nothing to pick, and no picker is drawn. A list is
offered in its own order. `:all` offers one zone per clock the world keeps
today, each named by its offset and the places that keep it (`(UTC+01:00)
Berlin, Paris, Madrid, …`), plus the reader's own: the server decides the
list, so every browser is offered the same. A hook composes the time and the
zone into the instant they mean and posts it under the field's own name, so
the action receives an ordinary timestamp. A custom form template, or a page
of your own, uses the same component:

```heex
<.zoned_datetime_input
  field={@form[:starts_at]}
  timezone={AshQuick.Scope.timezone(@scope)}
  label="Starts at"
/>
```

A plain `datetime-local` input reads its time as UTC, and shows the held value
in UTC.

## The extension on a resource

```elixir
use Ash.Resource,
  domain: MyApp.Catalog,
  extensions: [AshQuick]
```

That one line is the whole opt-in, and it **adds columns** — so it means a
migration:

| Added | When |
|---|---|
| `version` (integer, default `1`) | always, unless versioning is disabled |
| `active` (boolean, default `true`) | only when `activation` is declared |
| `inserted_at`, `updated_at` (`utc_datetime_usec`, `always_select?`) | unless declared `false` |
| `inserted_by_id`, `updated_by_id` (FKs to `:actor_resource`, not writable) | unless declared `false` |

Every one of them is add-if-absent: a resource that already defines the
attribute or the relationship keeps exactly what it wrote, and
`AshQuick.Bookkeeping.Verifier` refuses to compile a declaration that disagrees
with the fields in either direction. Generate the migration and read it before
running it.

It also attaches the audit change to every create, update and destroy, and
wires the resource's PubSub publications. See the `AshQuick` moduledoc for each
section: `liveness`, `display`, `labels`, `forms`, `lookup`, `activation`,
`versioning`, `bookkeeping`, `audit`, `read_only_fields`.

Every update is published, even one that changes no attribute, since a hook
may have changed what a page shows through other records. An update known to
change nothing a page shows, a print or a file download say, is listed in
`liveness do quiet [...] end`. A quiet update that changes nothing (on the same answer that leaves `version`,
`updated_by` and `updated_at` alone, see below) is not published, so it does
not make every open page on the record read it again. The atomic path cannot
tell, and publishes for any accepted input. A publication in the resource's
own `pub_sub` block is not affected.

### Versioning is on by default

Read this before adopting, because it changes how every write behaves.

Unless the resource says otherwise, every `:update` and `:destroy` is filtered
on the `version` the actor loaded and bumps it. Three consequences:

1. **`Ash.Error.Changes.StaleRecord` is a live failure mode every caller
   handles.** A write against a record someone else has since changed matches
   no row and comes back as that error rather than overwriting them.
2. **Each action keeps its own `require_atomic?`.** The lock works on both of
   Ash's paths, so an update that can run atomically does, and one with a
   change that cannot says `require_atomic? false` as it would on any
   resource. On the atomic path the lock is part of the `UPDATE`, and that
   includes `Ash.update_many/4` over loaded records, which locks each one in
   a single `MERGE` (PostgreSQL 17, see Installation).
3. **A bulk write by query, or by `:atomic_batches`, takes `:stream` instead
   when it changes anything the lock counts.** Ash hands both the same
   changeset without the rows' versions, so the lock cannot tell a query
   nobody loaded from records somebody did, and declines the atomic strategy
   for both. Pass `strategy: [:atomic, :stream]` and each row is locked in
   memory: a real changeset, notification and audit row per record. Correct,
   and not free: size the batches accordingly.

An update that ends up a genuine no-op neither bumps nor filters, and changes
to the bookkeeping fields do not count as changes for this purpose. On the
atomic path "no-op" is judged against the row being written, since that path
writes every accepted input: a value the actor did not change, but someone
else has since, is a change, and is locked.

Two writes are not checked. A hand-built record,
`%Post{id: id, version: String.to_integer(params["version"])}`, is checked
against the version it carries unless that is `1`: the lock cannot tell the
counter's default from a struct nobody filled in, so load the record to have
version `1` checked. And an upsert is not locked at all. The lock covers
updates and destroys; an upsert that meets an existing row writes over it
without checking or bumping `version`, so a copy loaded before it can still
save over what it wrote. Which fields it writes is up to Ash and the action's
`upsert_fields`; AshQuick does not choose them.

It is on rather than off because losing a concurrent write is silent and
unrecoverable. Turn it off where there is nothing to lose — an append-only log,
a row only one writer ever touches:

```elixir
ash_quick do
  versioning do
    enabled? false
  end
end
```

### Auditing records what changed, not only what was submitted

Every audited write lands one row per record in the store. `attributes` and
`arguments` say what the action was *given*; `changes` says what the values
*were* — a map keyed by attribute name:

```elixir
%{
  "name" => %{"from" => "Northwind", "to" => "Northwind Online"},
  "price" => %{"from" => %{"amount" => "10.00", "currency" => "USD"},
               "to" => %{"amount" => "12.50", "currency" => "USD"}}
}
```

A create records `to` alone, a destroy a `from` snapshot of every attribute, and
an attribute set to the value it already held is left out — an edit form posts
every field, and the entry is about what moved.

**`changes` is optional.** A store without the attribute keeps writing rows
exactly as it did before, with no `changes` key at all. An existing host opts in
by adding the column and generating the migration:

```elixir
# in the store resource, beside `attributes`
attribute :changes, :map, allow_nil?: false, default: %{}, public?: true
```

```console
$ mix ash.codegen add_audit_log_changes
```

Six things to know about what it holds:

* **`from` is the record the actor loaded**, never a fresh read — the entry is
  written inside the transaction of the write it describes. On an unversioned
  resource that value may already be stale. On a versioned one the optimistic
  lock rules that out, except for the attributes named in
  `versioning_ignored_attributes`, which are allowed to move underneath a held
  record by definition.
* **An unknown previous value is `from_unknown: true`, never `from: nil`.**
  `nil` is a value a column can hold, so "was blank" and "was never read" must
  not read alike. An attribute a `select` left out, a record that was never
  read — a hand-built `%Brand{id: id}` — and a bulk update run as one query,
  which never reads its rows, all reach it. A bulk destroy run as one query
  reads `from` off the rows it deleted, which are the rows as they stood.
* **An atomic write is recorded like any other.** An update that keeps Ash's
  default `require_atomic? true` needs no `require_atomic? false` for the
  audit. A value it sets atomically, an accepted input or an `atomic_update`
  such as `count + 1`, is recorded with `to` read off the record the write
  returned, since only the data layer knows what an expression came to; one
  the record does not hold is `to_unknown: true`. `attributes` reads the same
  as on the in-memory path. On an unversioned resource `from` is still the
  record the actor loaded, so two `count + 1` writes at once can leave an
  entry reading `from: 0, to: 2`.
* **An expression a change asked for is kept as `expr`**, as text beside the
  `from` and `to` it came to: `count: %{from: 0, to: 2, expr: "count + 1"}`
  stays true even where `from` is stale. It holds the values the action was
  given, `count + 5` for `^arg(:by)`, and reads as written, without the
  required and constraint checks Ash wraps it in for the data layer. An
  input, an update default such as `updated_at` and a versioned resource's
  counter keep none, even where they arrive as expressions. Once the action is
  given a sensitive argument, every value in its expressions reads
  `**redacted**`, since Ash can fold one into another; otherwise only a
  sensitive attribute's value does. That hides how a value was built, not the
  value: an attribute that is not sensitive still records in `to` what its
  expression came to, secret or not. The text is Ash's own rendering of the
  expression, which may change between Ash versions.
* **`has_many` and `many_to_many` changes are not in `changes`.** They are
  writes to the other resource: they show up in `arguments` as the input this
  action was given, and in that resource's own audit rows. An embedded resource
  is an attribute and is recorded whole on both sides.
* **A sensitive attribute is `"**redacted**"` on both sides**, and in its
  `expr`, unless it is named in `record_sensitive`. Whether it changed is still
  decided on the real values, so one that did not change is left out rather
  than shown as a change between two redactions.

### Auditing reads, for the actions you list

Reads are not recorded unless a resource lists the read actions to record.
List the ones that open a record, such as a confidential document:

```elixir
ash_quick do
  audit do
    read_actions [:open]
  end
end
```

* **Every record a listed read returns gets one row**, in the same store as a
  write: `action_type: :read`, the action's name, the record's id, the query's
  arguments (a `sensitive?` one redacted, as on a write), `attributes` and
  `changes` empty, and the same actor, real actor, IP, context and tenant. That
  holds for `Ash.read`, `Ash.get` or a code interface on a `get?` action, a
  page (the records on it), `Ash.stream!` (each batch) and the action loading
  a relationship of another resource.
* **Nothing else is recorded.** A read through an action that is not listed,
  such as a list or a search, writes no row: a page of twenty rows is not
  twenty reads anyone needs. Neither does a read that returns nothing (not
  found, or filtered out by policies), nor `Ash.can?` or `AshQuick.can?` on a
  listed action, which never run the read.
* **A read that cannot be recorded fails.** Reads run in no transaction, so
  the rows are written before the records are handed back, and a store that
  refuses them raises `AshQuick.Audit.WriteError`: the read returns nothing.
* **A QuickView details page reads its record more than once.** With a listed
  action as the details `default_action`, each visit records a read when the
  page first renders, another when it connects, and one more every time a
  change elsewhere makes it read the record again.
* **A resource that does not audit cannot list reads.** One with auditing off,
  the store itself and an embedded resource do not compile with
  `read_actions`, and neither does a name that is not one of the resource's
  read actions.

### What an audit row keeps from the context

A row's `context` holds two things: `action_source`, which every QuickView
stamps and a background job should set (`context: %{action_source:
"nightly_sync"}`), and the top-level context keys the resource lists. The same
rule covers writes and audited reads:

```elixir
ash_quick do
  audit do
    record_context [:import_batch]
  end
end
```

A listed key is kept only when its value is an atom or a string; a map, a list
or a struct under it is dropped. Every other key is dropped whatever its value.
An action's context also holds Ash's own keys and whatever the action carries
between its hooks, such as the bytes of a file it is about to hand back, and
none of that belongs in a table that is never rotated. A resource that writes
no row does not compile with `record_context`.

### What a resource must satisfy

Three things, each checked while the resource compiles.

**An `:id` attribute that addresses exactly one row.** AshQuick's views build a
list row's DOM ids from `record.id`, push the same value back over the socket to
say which row was clicked, and serve details at `/<path>/:id`. Either make it
the primary key or declare `identity :unique_id, [:id]` over the key the
resource already has. A composite-keyed join resource satisfies neither and
should not carry the extension until a page needs it.

The audit row records `record.id` as the audited record's identifier rather
than resolving the resource's declared primary key, so `:id` is in practice the
key AshQuick knows a record by. Making `:id` the primary key avoids the question
entirely. The id is written as text, and the store the installer generates
keeps `resource_id` as a `:string`, so one store takes entries for resources
keyed by UUIDs and by integers alike.

**A display label** — the field a record is named by, wherever AshQuick has to
name one: a dropdown option, a details header, a print filename. A resource
defining `:display_name` or `:name` needs no declaration. One named by neither
does not compile, because a uuid would only look like an answer:

```elixir
ash_quick do
  display do
    label :code
  end
end
```

`label` names an attribute, calculation or aggregate — a composed label belongs
in a calculation.

Keep the label short, since it is what a dropdown option shows. Where two
records can share one, `hint` names the field that tells them apart, and `path`
says which QuickView a record opens at when the router has more than one:

```elixir
ash_quick do
  display do
    label :name
    hint :email
    path "/users"
  end
end
```

A details page links the records it names — the writers in its "Created by"
header, and any field that stops at a relationship (`:store`) or reaches the
related record's label (`{[brand: :name], label: "Maker"}`) — for a reader
the nav's access control grants the record's page, with the hint as the
link's tooltip and in its accessible name. A list page links such columns the
same way, in each row. A reader with no link sees neither. The grant is a
route grant: it does not ask whether the reader may read that record. The
Live Users register and the impersonation banner show a person's hint beside
their label, and the register's search matches it.

Every relationship dropdown pointing at the resource shows the hint too: under
each option's label and each picked tag's, on a line of its own, and as
"Name (hint)" in a closed single-select. It is loaded with every option the dropdown reads, so
prefer an attribute or a cheap calculation over an aggregate. The dropdown
searches through the lookup action, never by what it shows, so that action
should match what the hint shows.

**A lookup action**, if anything searches the resource. One declaration stands
behind three surfaces: the list page, the export, and every relationship
dropdown pointing *at* this resource. The action has to exist, accept the
search argument (including `nil`), and declare `pagination`. A list page
opens at the action's `default_limit` and reads at most its `max_page_size`
rows (Ash's default is 250), whatever `?limit=` asks for. A "Rows per page"
select in the footer offers the default, then each of 10, 25, 50, 100 and 250
that is at least twice the default and within `max_page_size`, and writes
`?limit=`. It is left out when no pick would change the page: the default is
the only size, or every row fits on the smallest one.

The list asks for a total on every read, so its footer reads "Showing 1-20 of
340" and its pager links to the last page, unless the action says
`countable false`. That is the knob for a table too big to count: the footer
reads "Showing 1-20" with no total, and the pager steps to the previous and
next page, offering the next only while there are more rows.

```elixir
ash_quick do
  lookup do
    action :index           # the default
    search_argument :search # the default
  end
end
```

Nothing is generated for a resource that declares none — but a QuickView
listing it, or a form whose dropdown points at it, refuses to compile without
one. The error names the resource.

A QuickView also refuses to compile a form it could not save. A field with a
fixed set of values — an `Ash.Type.Enum`, or an atom with `one_of` — is picked
from a select, and a scalar is typed in. A list of scalars with no fixed set
(`{:array, :atom}`, `{:array, :string}`, ...) gets one text input, which posts
a string the list refuses. A page whose form, on any public create, update or
destroy, would offer one does not compile, and the error lists every such
field. Name its values, type its items with an `Ash.Type.Enum`, render it with
a form widget that posts a list, or leave it out of the action:

```elixir
attribute :marks, {:array, :atom}, constraints: [items: [one_of: [:red, :green]]]

use AshQuick.LiveView.QuickView,
  resource: MyApp.Item,
  form: [widgets: %{tags: &__MODULE__.tags_input/1}]
```

## Routing

A QuickView is routed through `AshQuick.LiveView.Router.quick_view/3` and
nothing else. The macro writes the base path into the route's metadata, and
that is where the view reads it back from at request time — so the path is
stated once and cannot drift from the module. A QuickView reached through a
hand-written `live/3` has no base path to find and says so rather than
rendering a page whose every link is broken.

```elixir
quick_view "/products", MyAppWeb.ProductLive.Quick
```

expands to four routes:

```elixir
live "/products",             MyAppWeb.ProductLive.Quick, nil
live "/products/create",      MyAppWeb.ProductLive.Quick, :create
live "/products/:id",         MyAppWeb.ProductLive.Quick, nil
live "/products/:id/:action", MyAppWeb.ProductLive.Quick, nil
```

`:only` and `:except` select from those four shapes — `:index`, `:create`,
`:show`, `:action`. **They name route shapes, not resource actions:** the single
`/:id/:action` route serves every action the resource has, so the router never
needs revisiting when one is added.

```elixir
quick_view "/audit_logs", MyAppWeb.AuditLogLive.Quick, only: [:index, :show]
quick_view "/items", MyAppWeb.ItemLive.Quick, except: [:create]
```

Omitting `:create` is how a resource that only ever comes into existence through
the system — an audit log, a materialised line item — is kept out of the "New"
flow.

A `quick_view` inside `scope "/admin"` answers `/admin/products` and builds its
links from `/admin/products` too.

## Actions too big for a modal

A create, an update or a destroy opens in a modal over the page it was opened
from. One whose form is too big for a modal (many fields, a nested list,
several attachments) opens as a page of its own when its resource says so:

```elixir
ash_quick do
  forms do
    full_page [:register, :import]
  end
end
```

The list's New button, a row's actions and a details page's buttons lead to
the action's URL as before; the page there draws the form, or the
confirmation, with nothing underneath. Cancel and a successful run return where
the modal would: to the page it was opened from, at its search, filters and
page, or, reached by a link, to the record's details page (the list for a
create). A create goes on to the record it made, and a destroy of the record
the page was about goes to the list. Each name must be a public create, update
or destroy, or the resource does not compile. A bulk run of the action still
opens in the modal over the list, which keeps the selection it runs over.

## Files an action produces

An action that makes a file of its own, a watermarked copy of an upload say,
hands it to the tab that ran it by marking the record it returns:

```elixir
Ash.Resource.put_metadata(record, :ash_quick_download, %{
  data: bytes,
  filename: "contract-watermarked.pdf",
  content_type: "application/pdf"
})
```

`:data` is the file's raw bytes, `:filename` the name the browser saves it
under and `:content_type` its media type. AshQuick never sets the mark; the
host's own change or action does, typically in an `after_action`. Run from a
QuickView (a row or bulk action, the details page or an action form), each
marked record's file is pushed over the LiveView socket once the action has
committed, and `attachAshQuick` saves it. Nothing is stored and no link is
handed out. A bulk run delivers one file per marked record. A mark missing a
key, holding non-binary data, or with an empty or non-string filename or
content type is logged, and the page says the action was recorded but its
file could not be delivered. An action run anywhere else (a seed, another
action, a controller) just returns the record.

The file travels base64-encoded in one `"ash_quick:download"` event, held
whole in the LiveView process on its way, so keep such files to a size that
is sensible to send that way. See `AshQuick.LiveView.DownloadUtils`.

## Generators

Two, and both write more than the file they are named after — because the thing
they generate is not reachable until three or four artifacts agree.

```console
$ mix ash_quick.gen.resource MyApp.Catalog.Product
```

Adds `extensions: [AshQuick]` to a resource that already exists, and names the
columns that costs before you run the migration it queues — read off the
resource as it stands, so a column it already declares is not reported. It also
says when the resource has no field to name a record by, which the extension
will otherwise refuse to compile over on the next `mix compile`.

```console
$ mix ash_quick.gen.quick_view MyApp.Catalog.Product
```

Writes the QuickView, with a starter field list taken from the resource's own
public attributes — without the ones AshQuick generated, and without the
sensitive ones. The file goes where the QuickViews the router already serves
are, laid out the way theirs are (`live/products/product_quick.ex` gives
`live/categories/category_quick.ex`) and always in a directory of its own, since
a custom `action_<name>.html.heex` applies to every QuickView in its directory;
`--file` names another. Routes it with one `quick_view/3` line, placed with the
QuickViews already there or in the live_session running
`AshQuick.LiveView.Mount`, named relative to that scope's alias, and with
`except: [:create]` when the resource has no create action. And grants the path
in the application's `AshQuick.AccessControl`, without which the route exists
and every navigation to it is refused: in its `@routes` list, or, for an access
control that lists routes per role, in the clause of each role
`--grant-to admin,editor` names.

A tile in the apps grid is a `group` in the nav — a decision about where the
page belongs, which is left to you.

## Storing files on local disk

`AshQuick.Storage.Local` stores attachments and exports on the server's own
disk, for an application on one node, or on several that share a volume. The
host backs that directory up. Uploads come over the LiveView socket and files
are read back through a plug at the application's own origin, so there is no
bucket, no CORS and nothing to add to a Content Security Policy.

```elixir
# config/config.exs
config :ash_quick, storage: AshQuick.Storage.Local

# config/runtime.exs
config :ash_quick, AshQuick.Storage.Local,
  root: "/var/lib/my_app/uploads",
  endpoint: MyAppWeb.Endpoint
```

```elixir
# lib/my_app_web/router.ex, outside any pipeline
forward "/ash_quick/files", AshQuick.Storage.Local.Plug
```

A `public/*` file is served to anyone with its path. Any other file needs the
token on its link: a `Phoenix.Token` signed with the endpoint's secret, naming
that one key and expiring after an hour by default (`:expires_in`). Like a
presigned URL, the link works for whoever holds it until then. Files a
browser would run, such as HTML or SVG, are sent as downloads, and every
response is sandboxed and `nosniff`. A key that could reach outside `:root`
is refused. `:at` moves the plug off `/ash_quick/files`. Set these options in
configuration, not on the forward: the links are built from it.
`mix ash_quick.check` reports a router that does not forward `:at` to the
plug, or forwards it inside a pipeline.

A host that wants the lifecycle callbacks on disk storage writes its own module
with `use AshQuick.Storage.Local`, which delegates the rest, and points
`:storage` at it.

Exports are deleted for you: `AshQuick.Storage.Sweeper`, started by the
`AshQuick` entry in the supervision tree, removes every file under `exports/`
older than `:export_retention` (a day by default, `nil` to keep them). Keep
it above an hour, the life of an export's download link. Nothing else is
deleted: a replaced attachment stays where it was.

## Serving files from a bucket only the app can reach

`AshQuick.Storage.S3` hands the browser the bucket itself: a presigned or
public bucket URL to read a file from, and a presigned `PUT` to upload one.
When the bucket sits on a private network, or refuses every request that is
not signed with the application's credentials, use `AshQuick.Storage.S3.Proxy`
instead. It keeps objects in the same kind of bucket, but every link it hands
out points at a plug on the application's origin, which reads the object from
the bucket and streams it on. Uploads come over the LiveView socket and the
server writes them to the bucket, so the browser never talks to it: no bucket
policy, no CORS and nothing to add to a Content Security Policy.

```elixir
# config/config.exs
config :ash_quick, storage: AshQuick.Storage.S3.Proxy

# config/runtime.exs
config :ash_quick, AshQuick.Storage.S3.Proxy,
  bucket: "my-app-uploads",
  endpoint: MyAppWeb.Endpoint
```

```elixir
# lib/my_app_web/router.ex, outside any pipeline
forward "/ash_quick/files", AshQuick.Storage.S3.Proxy.Plug
```

Links work as they do for `AshQuick.Storage.Local`: a `public/*` file by its
path, any other file with the `Phoenix.Token` on its link, and runnable types
sent as downloads. The plug reads the bucket in ranged chunks of
`:chunk_size` bytes (5 MiB by default), so a large file is never held in
memory whole, and it answers a single `Range` request with `206`, so a video
can seek. Every byte passes through the application, and an upload's write to
the bucket holds the page until it finishes, so keep `AshQuick.Storage.S3` for
a bucket the browser can reach. A host module that adds the lifecycle
callbacks does `use AshQuick.Storage.S3.Proxy`. `mix ash_quick.check` holds
the router to the forward as it does for local disk.

## What the host implements

Each is a behaviour or a resource, and each has a moduledoc that is the real
reference.

| Seam | What it is |
|---|---|
| `AshQuick.Scope` | `use` it on the host's scope struct. Generates `Ash.Scope.ToOpts` and the provenance AshQuick needs on top of it: the real actor behind an impersonation, the request IP, the reader's timezone and the actor's locale. Fails the compile if a named field is not on the struct. The IP is the peer address unless `:client_ip` names another source; behind a proxy, see `AshQuick.LiveView.Mount`. A controller reads the same address with `AshQuick.ClientIp.from_conn/1`. |
| The audit store | An Ash resource in the host app, named app-wide as `:audit_resource` or per resource under `audit do store ... end`. It must accept `resource_name`, `resource_id`, `action_type`, `action_name`, `attributes`, `arguments`, `context`, `actor_id`, `real_actor_id`, `ip`, `tenant`, and may also accept a `:map` `changes` — the only optional column. `actor_id` and `real_actor_id` must allow `nil`: a write with no actor is recorded with both `nil` (on a resource that stamps `inserted_by` / `updated_by`, only a destroy gets that far, since the stamp refuses a create or update with no actor). Keep it dumb — no policies, no validations: it is written inside the transaction of every audited write. |
| `AshQuick.Storage` | Where objects live: a URL to render one from (`url/2`), a URL to download one under a filename (`download_url/2`), storing a server-side file (`put_file/3`), and where a browser sends a picked file (`upload_target/2`, optional: without it uploads come over the LiveView socket). Plus optional lifecycle callbacks for routing an arriving upload and withholding objects that are not servable yet. Defaults to `AshQuick.Storage.S3`, which serves straight from the key and implements no lifecycle. `AshQuick.Storage.Local` keeps objects on the server's disk instead (see Storing files on local disk), and `AshQuick.Storage.S3.Proxy` serves a bucket only the application can reach through the application (see Serving files from a bucket only the app can reach). |
| `AshQuick.AccessControl` | Answers which routes a scope may navigate to. Named on the nav, and what every rendering of it filters through. Not `Ash.can?`: a filter policy allows the action and returns no rows, so `can?` says yes for a page that would be empty. |
| `AshQuick.Nav` | The host's navigation registry — one declaration the sidebar and the apps grid are both rendered from. QuickViews are discovered from the declared router; the declaration adds only what the router cannot say: a better label, an icon, a group, a non-QuickView path. |
| `AshQuick.PrintTemplate` | One module per print template: its label, what to load, and the HTML ChromicPDF renders. Chrome renders it on the server, so a template must escape every record value it interpolates and never put a URL from a record into `src`, `href` or CSS (see the module docs). A create or update action prints through it with `change {AshQuick.Print, template: ..., delivery: :print \| :download}`; the PDF is rendered after the action commits and reaches the browser over the LiveView socket, where `attachAshQuick` saves or prints it. |
| `AshQuick.ReadOnlyFields.Check` | `match?/2` over an actor and tenant, deciding whether that actor may write a field a `read_only_fields` entry names. For an actor it refuses, the field still reads everywhere, is left out of forms, and is stripped from the changeset. |

## Authorization on a surface

QuickView derives its controls from `Ash.can?` — a button the actor may not
press is not rendered. `AshQuick.can?/4` is that probe, and it stamps
`action_source` in the action's context, naming the surface doing the asking:
`:ash_quick_details`, `:ash_quick_list` or `:ash_quick_list_bulk`.

A policy can therefore be scoped to a single surface, hiding a control where
it is meaningless without that same policy firing for the JSON API, where the
precondition should surface as a validation rather than a `Forbidden`:

```elixir
policy action(:approve) do
  forbid_if context_equals(:action_source, :ash_quick_list)
  authorize_if MyApp.Checks.ActorIsReviewer
end
```

A control only opens the action: every create, update and destroy runs in a
modal over the page it was opened from, or on a page of its own for an action
the resource declares `full_page`; bulk runs always use the modal. The run is
stamped `AshQuick.form_source/0` (`:ash_quick_form`) however it was reached, by
the control, a hand-pushed event or a typed URL. That source is deliberately
**not** a surface: a policy scoped to the three above never fires at the run, so
a stale or forged run routes to the action's own validation (a 409 or 422)
instead of a `Forbidden`. A state gate therefore needs both a surface policy,
which hides the button, and a validation, which refuses the write. Where
QuickView must never run an action at all, forbid the form source too, as the
`AshQuick` moduledoc does for `:impersonate`:

```elixir
policy action(:impersonate) do
  forbid_if context_equals(:action_source, :ash_quick_list)
  forbid_if context_equals(:action_source, :ash_quick_form)
  authorize_if MyApp.Checks.ActorIsAdmin
end
```

An action the resource does not define answers `false` rather than raising:
surfaces probe for actions they merely hope are there.

Custom QuickView templates should call `AshQuick.can?/4` rather than a bare
`Ash.can?/2`, so their controls participate in the same policies.

A probe builds the action's changeset to check its policies, and building it
runs the action's changes and validations, on every page that probes. The bulk
menu probes each update and destroy it derives with no row selected, and the
list probes `:create`, so Ash builds those changesets over an empty struct,
where `changeset.data.id` is `nil`. A probe checks policies alone, so what a
validation answers never changes what the page offers; but a validation that
queries by the record's id still runs its query for every probe, over `nil`
for a record-less one. Defer it to the run, which is the only caller that
reaches a `before_action` hook:

```elixir
destroy :destroy do
  require_atomic? false
  validate MyApp.Catalog.Category.Validations.Unused, before_action?: true
end
```

or answer `:ok` for a probe, which `AshQuick.probe?/1` tells apart from a run:

```elixir
def validate(changeset, _opts, _context) do
  if AshQuick.probe?(changeset), do: :ok, else: check_unused(changeset.data.id)
end
```

## Sorting a list

A visitor sorts a list by clicking a column's header: ascending, then
descending, then back to the list's default order. The column goes first, and
the QuickView's `sort_by` and the action's own sort still order the rows it
ties on. One column at a time, carried in the URL as `?sort=name` or
`?sort=-owner.name`, kept while paging, searching and filtering, and followed
by the export.

Every list column Ash can sort in the data layer is sortable unless the
QuickView says otherwise: public attributes, aggregates and expression
calculations, of the resource or reached through public to-one relationships.
Calculations Ash computes in Elixir are not, nor is a `sensitive?` field, whose
masked value the order of the rows would give away (`sort_by` may not name one
either); a field or relationship with `sortable? false` opts out. Sorting by an
unindexed column reads the whole table, which is nothing on a small one; for a
large one, name the columns it has indexes for:

```elixir
use AshQuick.LiveView.QuickView,
  resource: MyApp.Sales.Order,
  list: [
    fields: [:number, :placed_at, :total, [customer: :name]],
    sortable: [:number, :placed_at, [customer: :name]]
  ]
```

`sortable: []` turns sorting off. Each entry has to be one of the list's
fields that Ash can sort, reached through public to-one relationships if it is
a path; the QuickView refuses any other when it compiles. A `?sort=` naming
any other column is dropped, and the list reads in its default order. The sort
goes through `Ash.Query.sort_input/3`, so field policies apply to it as they
do to a filter.

## Filtering a list

A list's filter button opens a form that builds a filter row by row: a field, an
operator and a value, in groups joined by AND or OR. The applied filter is
carried in the URL, shown above the list as chips, and followed by the export.
The form offers every public, `filterable?` attribute, aggregate and calculation
of a type it has a row for: strings, numbers, dates, timestamps, booleans,
UUIDs, atoms, amounts of money, fields with a fixed set of values, and lists of
such values (`{:array, :atom}` with `one_of` on its items, or a list of an
`Ash.Type.Enum`). The form leaves out a `sensitive?` field, which a filter would
give back a character at a time ("starts with 4", then "43"), a belongs_to
relationship's source attribute, a field Ash filters by simple equality only
(`filterable? :simple_equality`), a calculation with no `expression/2`, which a
filter cannot ask in SQL, and any field a field policy hides from the visitor on
every record. A visitor left with no field to filter by sees no filter button.

An AshMoney `:money` field, stored as its default `money_with_currency`, is
compared by its amount, with one in the same currency: `EUR 10` is in
euros, and `10` in the field's default currency, as its form input reads it,
or with none set, in the currency of Localize's locale. The form holds each
row with its currency, `USD 10`, so a link reads the same for every reader. A
row in another currency never matches, except under !=.

A list is filtered with Has Any Of, which keeps the rows whose list holds any
of the values picked. Is Empty is offered on every list, `allow_nil?: false`
or not, and counts one holding nothing as empty, as it counts a blank string
on a string field.

A filter travels in the URL, so a link can carry one written by hand. The
list reads only what the form could have written: rows on the fields the form
offers, by its operators, each with one value or, for Any Of and Has Any Of, a
list of them, joined by And or Or. It drops any other row before it reads, and
tells the visitor the filter couldn't be applied.

Filtering by an unindexed column reads the whole table, which is nothing on a
small one; for a large one, name the fields it has indexes for, in the order
the form lists them:

```elixir
use AshQuick.LiveView.QuickView,
  resource: MyApp.Sales.Order,
  list: [
    fields: [:number, :placed_at, :total, [customer: :name]],
    filterable: [:number, :placed_at, :status]
  ]
```

A field need not be a list column to be filterable, and field policies still
narrow the list for each visitor. `filterable: []` leaves the filter button
out. Each entry has to be a field the form offers; the QuickView refuses any
other when it compiles. A link whose filter has a row on any other field loses
that row before the list reads, and the visitor is told the filter couldn't be
applied.

`filterable:` also reaches one hop through a public belongs_to, to a field the
form would offer on the related resource:

```elixir
list: [
  fields: [:sku, :name, [brand: :name]],
  filterable: [:sku, :name, brand: :name, brand: :code]
]
```

The form lists such a field as "Brand › Name", draws its value as the brand's
field is drawn (a fixed set of values is picked, by the brand's own labels), and
the URL names its rows `brand.name`. A row asks whether the product's brand
matches, as `exists(brand, ...)`, inside which Ash applies the brand's read
policies, so a product is never kept for a brand its reader may not read; the
brand's field policies narrow the fields offered, as the list's own do. Both are
asked as a read through the relationship, so a policy written with
`accessing_from(Product, :brand)` holds as it does for the brand column. A brand
whose read policy refuses the reader outright, through the relationship too,
offers them none of its fields; one that only filters which brands they read
stays offered. Is Empty on such a field keeps a product with no brand, when the
relationship allows none, and one whose brand its reader may not read: the
column shows both blank. A list without `filterable:` offers no related field,
and a link's row on one it does not offer is dropped. Index the relationship's
source attribute and the related field on a large table. To-many relationships
and longer paths are refused when the QuickView compiles.

To add a related field to the ones the form offers without `filterable:`, name
`:defaults` among them:

```elixir
list: [
  fields: [:sku, :name, [brand: :name]],
  filterable: [:defaults, brand: :name]
]
```

`:defaults` stands for those fields, in their order, read off the resource, so
an attribute it gains later is offered too. It can go anywhere in the list, and
a field named before it comes first and is not offered twice. `:defaults` is
always the marker: a field named `defaults` is offered only through it, beside
the other defaults.

## Testing a details page

Each row on a QuickView details page carries a `data-field` attribute naming
the field's path: `:licence_holder_name` is `data-field="licence_holder_name"`,
and a relationship path joins every segment with `.`, so
`[vehicle: :chassis_number]` is `data-field="vehicle.chassis_number"`. The
name comes from the path, not the label, so rewording or translating a label
does not move it. A test asserts on one field's value with a plain selector:

```elixir
assert_has(session, ~s([data-field="licence_holder_name"] dd), text: value, exact: true)
assert_has(session, ~s([data-field="vehicle.chassis_number"] dd), text: vin, exact: true)
```

Always quote the name in the selector: a `.` and the `?` or `!` that end many
Ash attribute names (`active?`) are not valid in a bare CSS identifier.

PhoenixTest compares the visible text, so a value holding `'` or `&` matches as
it reads rather than as it is escaped in the HTML, and `exact: true` keeps the
assertion to exactly that value. A field can be listed twice on a page, so the
attribute is not an `id`. A custom details template that draws its own rows
can put the same attribute on them with
`AshQuick.LiveView.QuickField.data_field/1`.

## Checking a host in CI

A Spark verifier sees one resource's DSL and refuses to compile it if something
would fail at request time. Two kinds of mistake are outside that by
construction: a fact spanning *two* resources, and anything at all about the
router. `mix ash_quick.check` is those, and one fact about the configuration:

```console
$ mix ash_quick.check           # report, exit 0
$ mix ash_quick.check --strict  # report, exit 1 on any defect
```

Over the resources in the application's domains: two resources publishing on
one liveness prefix, so each one's writes land on the other's pages — a
collision no resource verifier can see, because it is only ever looking at one
of them. And, as an **advisory**, a resource carrying no extension at all.

Over the router: a QuickView declared with a plain `live/3`, a non-QuickView
carrying `ash_quick` metadata, a route served outside its base path, and a
control leading to a route `:only` or `:except` left out — rows link to
`<base>/<id>` and every public update or destroy, with inputs or without, opens
at `<base>/<id>/<action>`, neither of which consults the router. A private
action is never offered, so it needs no route.

Across the nav, the router and the access control: a nav path no route serves, a
granted route the router does not serve, a granted route with no link, and an
entry no role can reach. These need the set of routes *some* role holds, which
only the host can enumerate — implement the optional
`AshQuick.AccessControl.all_routes/0`. Without it they are reported as not run,
rather than passing for want of anything to compare against.

Over the configuration: Tower's `:reporters` left at its default, which keeps
the errors a page could not explain in memory and sends them nowhere — see
[Error reporting](#error-reporting).

What it deliberately does **not** report: whether a resource turned versioning
or auditing off, or whether it has a lookup action. `enabled? false` is already
the decision, stated where it belongs; and whether a resource needs a lookup
action is not a fact about the resource — see `AshQuick.Lookup.Verifier`.

`--strict` fails on defects and ignores advisories: a number a project watches
go down must not be a number that blocks a deploy. The default is advisory
throughout, because an adoption path that demands a big-bang conversion does not
get taken. A divergence the application has decided to keep is recorded rather
than silenced with a flag:

```elixir
config :ash_quick,
  check: [exempt: [unroutable_action: ["/file_objects/:id/reference"]]]
```

`AshQuick.Check` documents every check and what it keys an exemption on.

## Optional dependencies

Each one turns a feature on; without it the feature is absent rather than
broken.

| Dependency | What it enables |
|---|---|
| `exceed`, `nimble_csv` | Excel and CSV export |
| `chromic_pdf`, `merge_pdf` | Printing (`AshQuick.Print`) |
| `ex_aws`, `ex_aws_s3` | `AshQuick.Storage.S3`, the default object store, and `AshQuick.Storage.S3.Proxy` |
| `ex_money` | Rendering `Money` values |
| `localize` | Locale-aware date, time and money formatting |

Export is feature-detected at runtime — `AshQuick.Config.exports_enabled?/0` —
so its control simply does not appear. Printing has no control of its own: an
action that carries `AshQuick.Print` needs ChromicPDF, and a resource with the
`AshQuick` extension does not compile with such an action until it is there,
unless the host names its own `AshQuick.PdfRenderer` as `:pdf_renderer` (a
test suite with no Chrome does, to read what a print says).
A host that points `:storage` at its own
object store, or at `AshQuick.Storage.Local`, never loads the ExAws ones.

## The example app

`example/` is a small Phoenix + AshPostgres application that hosts this library
from the checkout it sits in. It is where the paths that need a host are tested
— the optimistic lock reaching SQL, the audit row written inside the
transaction of the write it records, a presign taking custody through the
storage seam, a QuickView driven end to end behind a session — and it doubles
as the demo a README cannot be:

```console
$ cd example
$ mix setup
$ mix phx.server   # http://localhost:4000, sign in at /login
```

Five seeded users across three roles and two shops, so the sidebar, the apps
grid, every button and the rows themselves change with who you are.
`example/README.md` has the rest, including which seam is wired where.

## Status

Extracted from a production application.
