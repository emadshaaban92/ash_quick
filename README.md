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
(`AshQuick.Nav`), print templates (`AshQuick.PrintTemplate`) and field
restriction checks (`AshQuick.FieldRestrictions.Check`).

The moduledocs are the reference. This is the order to read them in.

## Installation

```elixir
def deps do
  [{:ash_quick, github: "emadshaaban92/ash_quick"}]
end
```

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
  error_translator: {MyAppWeb.CoreComponents, :translate_error},
  timezone: "Etc/UTC"
```

`:endpoint` and `:actor_resource` are read with `Application.compile_env/2`,
because resources bake them in while they compile: the endpoint becomes each
resource's PubSub publications, the actor resource becomes its `created_by` /
`updated_by` relationships. Declared in `runtime.exs`, a release would load
them long after the resources were built against `nil`, and nothing would say
so — the pages would simply be dead and the columns empty. `compile_env` turns
that into a refusal to boot. Everything else is read at runtime and may move.

`AshQuick.Config` documents every key, including the S3 ones,
`:humanize_overrides`, `:refetch_window` and `:impersonation_max_age`.

### Assets

Two lines, so QuickViews are styled and each browser tab carries its own
session. Without the `@source` line every QuickView renders unstyled — the
library's classes live in its own `lib/`, which the host's Tailwind build does
not scan by default.

```css
/* assets/css/app.css */
@source "../../deps/ash_quick/lib/**/*.*ex";
```

```javascript
// assets/js/app.js
import { browserSessionParams, initBrowserSession } from "../../deps/ash_quick/assets/js/browser_session"
import { initLocale } from "../../deps/ash_quick/assets/js/locale"

let liveSocket = new LiveSocket("/live", Socket, {
  // A function, so every reconnect re-reads the tab's identity.
  params: () => ({ _csrf_token: csrfToken, ...browserSessionParams() }),
  hooks: hooks
})

initBrowserSession(liveSocket)
initLocale()
```

`browserSessionParams` is the id a tab mints for itself and replays on every
connect — the unit `AshQuick.BrowserSessionPresence` registers, and the one its
`revoke/1` cuts an impersonation off at. `initLocale` applies the `lang` and
`dir` the connected mount pushes, which the dead render could not have known.

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

`AshQuick.BrowserSessionPresence` goes in the application's tree, after the
PubSub server and before the endpoint. Leaving it out costs the register of
signed-in tabs and nothing else — the mount warns once per navigation and
serves the page.

```elixir
children = [
  {Phoenix.PubSub, name: MyApp.PubSub},
  AshQuick.BrowserSessionPresence,
  MyAppWeb.Endpoint
]
```

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
| `created_at`, `updated_at` (`utc_datetime_usec`, `always_select?`) | unless declared `false` |
| `created_by_id`, `updated_by_id` (FKs to `:actor_resource`) | unless declared `false` |

Every one of them is add-if-absent: a resource that already defines the
attribute or the relationship keeps exactly what it wrote, and
`AshQuick.Bookkeeping.Verifier` refuses to compile a declaration that disagrees
with the fields in either direction. Generate the migration and read it before
running it.

It also attaches the audit change to every create, update and destroy, and
wires the resource's PubSub publications. See the `AshQuick` moduledoc for each
section: `liveness`, `display`, `lookup`, `activation`, `versioning`,
`bookkeeping`, `audit`, `field_restrictions`.

### Versioning is on by default

Read this before adopting, because it changes how every write behaves.

Unless the resource says otherwise, every `:update` and `:destroy` is filtered
on the `version` the actor loaded and bumps it. Three consequences:

1. **`require_atomic? false` is forced on every `:update` and `:destroy`.** The
   lock is decided in a `before_action` against the final changeset, and
   reaching that changeset needs the non-atomic path.
2. **`Ash.bulk_update` therefore never takes the atomic path** on a versioned
   resource. It runs `:stream` — a real changeset, notification and audit row
   per record. Correct, and not free: size the batches accordingly.
3. **`Ash.Error.Changes.StaleRecord` is a live failure mode every caller
   handles.** A write against a record someone else has since changed matches
   no row and comes back as that error rather than overwriting them.

An update that ends up a genuine no-op neither bumps nor filters, and changes
to the bookkeeping fields do not count as changes for this purpose.

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

### What a resource must satisfy

Three things, each checked while the resource compiles.

**An `:id` attribute that addresses exactly one row.** AshQuick's views build a
list row's DOM ids from `record.id`, push the same value back over the socket to
say which row was clicked, and serve details at `/<path>/:id`. Either make it
the primary key or declare `identity :unique_id, [:id]` over the key the
resource already has. A composite-keyed join resource satisfies neither and
should not carry the extension until a page needs it.

The audit row currently records `record.id` as the audited record's identifier
rather than resolving the resource's declared primary key, so `:id` is in
practice the key AshQuick knows a record by. Making `:id` the primary key
avoids the question entirely.

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

**A lookup action**, if anything searches the resource. One declaration stands
behind three surfaces: the list page, the export, and every relationship
dropdown pointing *at* this resource. The action has to exist, accept the
search argument (including `nil`), and declare `pagination`.

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

## What the host implements

Each is a behaviour or a resource, and each has a moduledoc that is the real
reference.

| Seam | What it is |
|---|---|
| `AshQuick.Scope` | `use` it on the host's scope struct. Generates `Ash.Scope.ToOpts` and the provenance AshQuick needs on top of it: the real actor behind an impersonation, the request IP, the actor's timezone and locale. Fails the compile if a named field is not on the struct. |
| The audit store | An Ash resource in the host app, named app-wide as `:audit_resource` or per resource under `audit do store ... end`. It must accept `resource_name`, `resource_id`, `action_type`, `action_name`, `attributes`, `arguments`, `context`, `actor_id`, `real_actor_id`, `ip`, `tenant`. Keep it dumb — no policies, no validations: it is written inside the transaction of every audited write. |
| `AshQuick.Storage` | Resolves attachment values to fetchable URLs, plus optional lifecycle callbacks for routing an arriving upload and withholding objects that are not servable yet. Defaults to `AshQuick.Storage.S3`, which serves straight from the key and implements no lifecycle. |
| `AshQuick.AccessControl` | Answers which routes a scope may navigate to. Named on the nav, and what every rendering of it filters through. Not `Ash.can?`: a filter policy allows the action and returns no rows, so `can?` says yes for a page that would be empty. |
| `AshQuick.Nav` | The host's navigation registry — one declaration the sidebar and the apps grid are both rendered from. QuickViews are discovered from the declared router; the declaration adds only what the router cannot say: a better label, an icon, a group, a non-QuickView path. |
| `AshQuick.BrowserSessionPresence` | The live register of signed-in tabs. Supervised, not implemented — listed here because the tree entry is the host's. `AshQuick.LiveView.BrowserSessionsLive` is the page that reads it. |
| `AshQuick.PrintTemplate` | One module per print template: its label, what to load, and the HTML ChromicPDF renders. Listed on a QuickView under `:print_templates`. |
| `AshQuick.FieldRestrictions.Check` | `match?/2` over an actor and tenant, deciding whether a restricted field is visible and writable. Hides the field in forms and strips it from the changeset. |

## Authorization on a surface

QuickView derives its controls from `Ash.can?` — a button the actor may not
press is not rendered. `AshQuick.can?/4` is that probe, and it stamps
`action_source` in the action's context, naming the surface doing the asking:
`:ash_quick_details`, `:ash_quick_list` or `:ash_quick_list_bulk`.

A policy can therefore be scoped to a single surface — hiding a control where
it is meaningless without that same policy firing for the JSON API, where the
precondition should surface as a validation rather than a `Forbidden`:

```elixir
policy action(:impersonate) do
  forbid_if context_equals(:action_source, :ash_quick_list)
  authorize_if MyApp.Checks.ActorIsAdmin
end
```

Two things to know about it. An action the resource does not define answers
`false` rather than raising — surfaces probe for actions they merely hope are
there. And a form submit is stamped `:ash_quick_form`, which is deliberately
**not** a surface source: a policy scoped to the three above never fires at
submit, so a stale or forged submit routes to the action's own validation (a 409
or 422) instead of a `Forbidden`. The button-hiding already happened at the
probe.

Custom QuickView templates should call `AshQuick.can?/4` rather than a bare
`Ash.can?/2`, so their controls participate in the same policies.

## Optional dependencies

Each one turns a feature on; without it the feature is absent rather than
broken.

| Dependency | What it enables |
|---|---|
| `exceed`, `nimble_csv` | Excel and CSV export |
| `chromic_pdf`, `merge_pdf`, `briefly` | Printing |
| `ex_aws`, `ex_aws_s3` | `AshQuick.Storage.S3`, the default object store |
| `ex_money` | Rendering `Money` values |
| `localize` | Locale-aware date and time formatting |
| `tower` | Reporting the errors a page could not explain |

Export and print are feature-detected at runtime —
`AshQuick.Config.exports_enabled?/0` and `print_enabled?/0` — so the export and
print controls simply do not appear. A host that points `:storage` at its own
object store never loads the ExAws ones.

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

Three seeded users, one per role, so the sidebar, the apps grid and every
button change with who you are. `example/README.md` has the rest, including
which seam is wired where.

## Status

Extracted from a production application. An Igniter installer, which will
generate the audit store and write the configuration, is not here yet.
