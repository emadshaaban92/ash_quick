---
name: ash-quick
description: "Use this skill when working with AshQuick — the declarative CRUD LiveView system for Ash resources. Load it when a module has `use AshQuick.LiveView.QuickView`, when a resource carries `extensions: [AshQuick]` or an `ash_quick do` block, when a router uses `quick_view/3`, or when hitting `Ash.Error.Changes.StaleRecord` on an update. Covers QuickView configuration, field formats, widgets, lifecycle hooks, the action modal, custom action templates, navigation, filters, bulk actions, printing, real-time updates, and the conventions a resource must satisfy."
---

# AshQuick QuickView

AshQuick (`deps/ash_quick/`) generates complete CRUD LiveViews from declarative
configuration. A project that has adopted it usually routes most of its
list/detail/create/update pages through QuickView rather than through
hand-written LiveViews — check the router for `quick_view/3` before writing a
new page by hand.

## When to use QuickView vs standard LiveView

- **QuickView**: Standard CRUD pages (list/detail/create/update) for an Ash resource
- **Standard LiveView**: Custom pages with non-CRUD workflows, dashboards, or complex interactions

## Minimal example

```elixir
defmodule MyAppWeb.ProductLive.Quick do
  use AshQuick.LiveView.QuickView,
    resource: MyApp.Catalog.Product,
    list: [
      fields: [:code, :name, :price, :quantity],
      new_action_label: "Add Product"
    ],
    details: [
      fields: [:code, :name, :description, :price, :quantity, :inserted_at]
    ]
end
```

## Generate rather than hand-write

Three tasks, and each writes every artifact the thing it generates needs in
order to work — which is more than the file it is named after. Reach for them
before writing a QuickView, a route or an audit store by hand.

```console
$ mix igniter.install ash_quick                      # config, audit store, nav, access control, router import
$ mix ash_quick.gen.resource MyApp.Catalog.Product   # the extension, and the columns that costs
$ mix ash_quick.gen.quick_view MyApp.Catalog.Product # the view, its route, and the grant for it
```

`mix ash_quick.gen.quick_view` derives the field list from the resource's own
public attributes (without the ones AshQuick generated, and without the
sensitive ones), routes it with one `quick_view/3` line named relative to the
enclosing `scope` alias, adds `except: [:create]` when the resource has no
create action, and grants the path in the application's `AshQuick.AccessControl`
— the last of which is what keeps a new page from 403ing with nothing to say
why.

`mix ash_quick.gen.resource` takes an existing resource onto the extension
through `mix ash.extend`, and reports the columns that adds before you run the
migration it queues.

## Router setup

Routes are declared with `quick_view/3`, which states the path once and pins
it to the routes it generates. The QuickView reads it back from the route, so
the path is never spelled in the view itself:

```elixir
import AshQuick.LiveView.Router

quick_view "/products", ProductLive.Quick
```

That declares all four routes: `/products`, `/products/create`,
`/products/:id` and `/products/:id/:action`.

`:only` and `:except` pick from those four shapes — `:index`, `:create`,
`:show`, `:action`. They never name resource actions; one `/:id/:action`
route serves every action the resource has.

```elixir
quick_view "/audit_logs", AuditLogLive.Quick, only: [:index, :show]
quick_view "/items", ItemLive.Quick, except: [:create]
```

Dropping `:create` is how a resource that only ever comes from the system is
kept out of the "New" flow. Routing a QuickView with a plain `live/3` raises
at request time, because it leaves the view with no base path to build links
from.

The layout must be set on the `live_session` (QuickView does not set one).

## Navigation

A routed QuickView appears in the sidebar with no further work: `AshQuick.Nav`
discovers it by walking the router for the base path `quick_view/3` records,
labels it from the resource's `plural_name` and draws a generic icon.

The host's `AshQuick.Nav` module (registered as `:nav` in config) states only
what the router cannot — an icon, a label the resource would get wrong, a
group, or a page that is not a QuickView at all:

```elixir
nav do
  entry "/products", icon: "hero-cube-solid"
  entry "/scan", icon: "hero-viewfinder-circle-solid"
  entry "/profile", label: "My Profile", icon: "hero-user-circle-solid"

  group "Catalog", ~w(/categories /products /brands), icon: "hero-archive-box-solid"
end
```

An icon is a heroicon class, a `{module, function}` naming a function
component, or a one-argument function — the last two render any markup they
like and are handed the `:class` for the surface they are drawn on.

A group is a heading in the sidebar and one tile in the apps grid, linking to
the first path in its list the viewer can reach. Groups hold path
*references*, so a path may sit in more than one — but a reference is all it
is, so a path named by a group and by no entry renders nowhere.

Put a new route in a group, or it has no tile in the apps grid.

`AshQuick.Nav.Verifier` catches only what the declaration answers on its own —
a duplicate path, an empty group, a group naming a path no entry covers. It
cannot read the router (the router compiles the views the nav names, so that
would be a cycle) and it knows nothing of roles. The rest is
`mix ash_quick.check`'s, over the assembled application: a nav path no route
serves, a granted route the router does not serve, a granted route no entry
renders, and a nav entry no role can reach (see "Checking the application"
below). A route in no group is not reported; it simply has no tile.

## Options

### Required
- `:resource` — The Ash resource module

The URL is not an option here — it is declared in the router with
`quick_view/3` and arrives as the `@base_path` assign.

### Optional (top-level)
- `:sort_by` — Default sort (e.g. `[name: :asc]`)
- `:load` — Extra fields/relationships to load on every query
- `:base_filter` — Ash expression always applied to list queries
- `:sidebar` — Navigation sidebar, defaults to `true`. Set `false` for full width.
- `:liveness_options` — Tuning for real-time updates. Liveness itself is the
  resource's call, not the view's (see below) — most views need none of this.
  - `:recursive?` — Defaults to `true`: walk the fetched data and listen to
    every related record it materialized. `false` stops at the rows on screen.
  - `:extra_records` — Function returning records or `{resource, id}` pairs to
    watch on top of the derived ones
  - `:refetch_window` — Minimum ms between refetches
  - `:pub_sub` — Custom PubSub module
- `:filters` — Predefined toggle filters as a list of maps
- `:export_fields` — Fields for Excel/CSV export

### List options (`:list`)
- `:fields` — Fields in the list table
- `:load` — Extra loads for list queries only
- `:default_action` — Read action for listing (default `:index`)
- `:new_action_label` — Label for "Create" button
- `:bulk_actions` — the menu over a selection, a list or `fn socket -> [...] end`.
  Items are action names (a public update or destroy) or custom items
  (`%{title:, func:}` / `%{title:, link:}`). Given, the menu is exactly that
  list, in order; not given, it is every public update and destroy without
  inputs. Names are checked at compile time (a function's result when the menu
  is built); an action taking an upload is refused

### Details options (`:details`)
- `:fields` — Fields in the detail view
- `:load` — Extra loads for detail queries only (use for heavy relationships)
- `:default_action` — Read action for details (default `:read`)
- `:featured_actions` — Actions shown as prominent buttons (default `[:update, :destroy]`)

## Field formats

A field is either a **path** or a **{path, opts}** tuple. A path can be a simple
atom (`:name`) or a relationship navigation (`[seller: :name]`).

```elixir
# Simple field
:name

# Relationship path
[seller: :name]

# Field with opts (preferred format when customizing)
{:name, label: "Full Name"}
{:state, widget: &__MODULE__.state_widget/1}
{:platform_roles, label: "Platform Roles", widget: &__MODULE__.roles_widget/1}

# Relationship path with opts
{[seller: :name], label: "Seller Name"}
```

**Supported opts:**
- `:label` — Custom display label (defaults to humanized field name)
- `:widget` — Custom rendering function (see Widgets section below)

**Prefer `{path, opts}` over the legacy `{path, "label"}` format.**

## Widgets

Widgets are custom rendering functions for field values. They receive assigns
containing `:value` (the resolved field value) and return HEEx markup. Widgets
work in both list and details views.

```elixir
# In field definition
list: [
  fields: [
    :name,
    {:state, widget: &__MODULE__.state_widget/1},
    {:due_at, widget: &__MODULE__.relative_date_widget/1}
  ]
]

# Widget function — receives assigns with @value
def state_widget(assigns) do
  ~H"""
  <span class={[
    "badge badge-sm",
    case @value do
      :draft -> "badge-ghost"
      :confirmed -> "badge-info"
      :done -> "badge-success"
      _ -> "badge-ghost"
    end
  ]}>
    {Utils.humanize(@value)}
  </span>
  """
end
```

Key points:
- Widgets are user-defined functions, not a built-in library
- The function receives assigns with `@value` already resolved from the record
- Must be a function capture (`&Module.fun/1` or `&fun/1`)

## Load option

The `:load` option tells Ash to load extra fields/relationships alongside the
query. It can be set at three levels:

- **Top-level** `:load` — applied to every query (list, details, forms)
- **`:list` > `:load`** — applied only to list queries (combined with top-level)
- **`:details` > `:load`** — applied only to detail queries (combined with top-level)

Use `:load` for data needed by custom action templates, custom events, or
anything beyond the declared `:fields`.

```elixir
use AshQuick.LiveView.QuickView,
  resource: MyApp.Sales.Order,
  load: [:computed_total],                  # loaded everywhere
  list: [load: [:line_count]],              # list-only
  details: [load: [lines: [:product]]]      # details-only (heavy relationship)
```

## Action routing convention

URL determines view type:
- `id: nil` + read action -> **List view**
- `id: <uuid>` + read action -> **Details view**
- `id: nil` + create action -> **Create modal** over the list
- `id: <uuid>` + update or destroy action -> **Action modal** over the record's
  page: a form when the action takes input, a confirmation when it takes none

Action resolved from (priority order):
1. `action` URL parameter
2. `live_action` from router (e.g. `:create`)
3. Configured default action

## Actions open in a modal

Every create, update and destroy renders in a modal (`#ash-quick-action-modal`)
over the page it was opened from — a form when the action takes input, a
confirmation (its name, the record, Cancel / Confirm) when it takes none. There
is no `data-confirm` and no browser dialog anywhere.

- The page underneath is a snapshot of the list or details the visitor was on,
  rendered `inert`, at its search, filters and page. A URL reached with nothing
  before it (a link, a refresh) opens over the record's details, or the list for
  a create.
- Closing (✕ or Cancel) patches back to that page. Running
  the action does too, except that a create goes to the record it made and a
  destroy opened over the record it destroyed goes to the list. While the
  action runs it can't be closed: ✕ and Cancel are disabled, Save or Confirm
  shows a spinner, and the form's controls are locked until the reply. The
  keyboard half of the lock is the colocated hook
  `AshQuick.Components.SubmitLock`: the host spreads
  `import { hooks as ashQuickHooks } from "phoenix-colocated/ash_quick"` into
  its LiveSocket `hooks`. A custom template that renders its own `<.form>`
  rather than `simple_form/1` opts in with an `id` and
  `phx-hook="AshQuick.Components.SubmitLock"`.
- A custom `action_<name>.html.heex` for a form renders inside the modal; a
  custom read template renders as the page underneath.
- A control is drawn where `AshQuick.can?/4` allows it on its surface. A click
  (or a hand-pushed event, or a typed URL) only opens the action's URL; the
  action runs stamped `AshQuick.form_source/0`. So a policy scoped to a surface
  hides a control and never refuses the run — pair it with a validation, as for
  any form, or forbid `:ash_quick_form` where QuickView must not run the action
  at all.
- A bulk action opens the modal over the list and keeps the selection: a
  confirmation ("Applies to N selected rows") or a form whose values apply to
  every row. The form checks the inputs alone (types, constraints, required);
  record-dependent validations run in the run. ✕ / Cancel close it without
  running. The run (`Ash.bulk_update` / `Ash.bulk_destroy`) takes the selected
  rows the list still shows, stamped `:ash_quick_form`; rows it did not write
  stay selected and are reported. `:ash_quick_list_bulk` only hides a menu item.
- In LiveView tests, target the modal: `form("#ash-quick-action-modal form")`,
  and submit it to confirm. The page underneath is in the DOM too, so a bare
  `"form"` selector matches its forms as well.

## Custom actions: seeding a form

A QuickView form tells an action's changes what it is doing, under
`AshQuick.form_stage_key/0` (`:ash_quick_form_stage`) in the changeset's
context. Read it with `AshQuick.form_stage/1`, never by the key or its atoms:

- `AshQuick.form_build_stage/0` (`:build`): the form is being built, once, as
  it opens (prefills included). Whatever the build sets on the action's
  inputs, an argument or an accepted attribute, becomes the form's initial
  params, so it holds until the person changes it. Only an input the form
  shows carries a seed to the run: one the actor cannot see (a field
  restriction hides it) is dropped at the first `phx-change`. Set such a value
  at `form_submit_stage/0`, or in a change that runs at every stage.
- `AshQuick.form_validate_stage/0` (`:validate`): the open form is validated,
  on every `phx-change` and upload.
- `AshQuick.form_submit_stage/0` (`:submit`): submitted from one, a bulk
  action's run included. The run carries `action_source:
  AshQuick.form_source/0` beside it, as before.
- `nil`: any other caller (code, JSON API, `AshQuick.can?/4` probes, a form's
  nested forms).

So a change can fill an argument from a computed value when the form opens,
without filling it in for a caller that simply left it out, or again after the
person cleared it:

```elixir
def change(changeset, _opts, _context) do
  if AshQuick.form_stage(changeset) == AshQuick.form_build_stage() do
    Ash.Changeset.set_argument(changeset, :note, suggested_note(changeset))
  else
    changeset
  end
end
```

A change's `change/3` sees the stage, but not `action_source`: the run's own
context is merged in after the changes ran. A hook (`before_action` and later)
or a policy sees both.

## Custom action templates

Place `action_<name>.html.heex` in the same directory as the QuickView module:

```
lib/my_app_web/live/orders/
  quick.ex                    # QuickView module
  action_read.html.heex       # Custom details template for :read
```

Template has access to: `@record`, `@resource`, `@params`, `@scope`, `@options`.
`AshQuick.Components` is imported and `Phoenix.LiveView.JS` is aliased.

That import is the whole module, into every QuickView. A QuickView's own
helper with the same name and arity as a public function of
`AshQuick.Components` fails to compile once it is called unqualified
("imported ... conflicts with local function"). So adding a public function
there is a potentially breaking change for hosts. Put helpers that are not
components in a module QuickView does not import, as
`AshQuick.LiveView.FieldErrors` is.

A host `input/1` generated by `phx.new` shows a field's errors on
`used_input?/1` alone, which misses a field a refused save left out of its
params (an empty list of nested forms, an attachment with nothing picked),
so the error it failed on never shows beside it in a custom template. Have it
decide with `AshQuick.LiveView.FieldErrors.for_field/1` instead, which
translates through the configured `:error_translator`:

```elixir
def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
  assigns
  |> assign(field: nil, id: assigns.id || field.id)
  |> assign(:errors, AshQuick.LiveView.FieldErrors.for_field(field))
  # ...
end
```

A host `widget:` built on `LiveSelect` posts its value from a hidden input,
which `used_input?/1` cannot judge, and a cleared select posts the same blank
as one never touched. Read its errors with `FieldErrors.for_select/1` and
render `FieldErrors.used_marker/1` beside it. The form marks the field the
change event came from, and the marker keeps that mark on the page:

```elixir
def roles_widget(assigns) do
  assigns = assign(assigns, :errors, AshQuick.LiveView.FieldErrors.for_select(assigns.phx_field))

  ~H"""
  <LiveSelect.live_select field={@phx_field} mode={:tags} options={...} />
  <AshQuick.LiveView.FieldErrors.used_marker field={@phx_field} />
  <.error :for={msg <- @errors}>{msg}</.error>
  """
end
```

To use host app components, import them in the QuickView module **before** `use`:

```elixir
defmodule MyAppWeb.ExampleLive.Quick do
  import MyAppWeb.CoreComponents
  use AshQuick.LiveView.QuickView, ...
end
```

## Lifecycle hooks

Two overridable hooks:

- `after_mount(socket, options)` — Add custom assigns after mount
- `after_handle_params(socket, options)` — Redirect, add assigns, or modify per-action

```elixir
defp after_handle_params(%{assigns: %{path: "/profile"}} = socket, _options) do
  socket |> push_patch(to: "/profile/#{socket.assigns.current_user.id}")
end

defp after_handle_params(socket, _options), do: socket
```

## Custom handle_event

You can define custom `handle_event` callbacks alongside QuickView:

```elixir
def handle_event("custom_action", params, socket) do
  # Custom logic here
  {:noreply, socket}
end
```

## Gating controls: `AshQuick.can?/4`

QuickView derives its buttons and row actions from `Ash.can?` — a control the
actor may not use is not rendered. The probe is `AshQuick.can?/4`, and it
stamps `action_source` into the action's context, naming the surface asking:
`:ash_quick_details`, `:ash_quick_list` or `:ash_quick_list_bulk`.

**In a custom action template, call `AshQuick.can?/4` rather than a bare
`Ash.can?/2`**, or the control will not participate in surface-scoped
policies:

```elixir
<%!-- a record-scoped probe: policies see the row --%>
<.button :if={AshQuick.can?({@record, :approve}, @scope, :ash_quick_details)} ...>

<%!-- record-less, for an action with no row yet --%>
<.button :if={AshQuick.can?({@resource, :create}, @scope, :ash_quick_list)} ...>
```

Pass the **record** wherever there is one. A record-less probe gives a filter
check no row to evaluate, so a policy that would have allowed this particular
record can come back `false`.

That is what lets a policy hide a control on one surface without firing for
non-QuickView callers, where the same precondition should surface as a
validation rather than a `Forbidden`:

```elixir
policy action(:approve) do
  forbid_if context_equals(:action_source, :ash_quick_list)
  authorize_if MyApp.Checks.ActorIsReviewer
end
```

Two things to know:

- An action the resource does not define answers `false` rather than raising.
  Surfaces probe for actions they merely hope are there — the list view asks
  about `:create` before offering its button.
- Every run is stamped `AshQuick.form_source/0` (`:ash_quick_form`) — a form
  or a confirmation, one record or a bulk selection — and that is deliberately
  **not** one of the three surface sources. A policy scoped to those never
  fires at the run, so a stale or forged run routes to the action's own
  validation (409/422) instead of a `Forbidden`. **A state gate therefore
  needs both**: the policy hides the button, and an always-on validation
  refuses the write. A policy alone leaves the action open to anyone typing
  its URL or pushing the event; a validation alone renders a button that
  always errors. Where QuickView must never run an action (one only a page of
  your own can finish, like `:impersonate`), also
  `forbid_if context_equals(:action_source, :ash_quick_form)`.

## Predefined filters

```elixir
filters: [
  %{"name" => "active", "label" => "Active", "expression" => %{"active" => %{"eq" => true}}},
  %{"name" => "inactive", "label" => "Inactive", "expression" => %{"active" => %{"eq" => false}}}
]
```

## Real-time updates

**A QuickView is live when its resource publishes — there is nothing to declare
on the view.** The resource's `ash_quick.liveness` block is the switch:

```elixir
use Ash.Resource, extensions: [AshQuick]   # publishes, so its QuickViews are live
```

```elixir
ash_quick do
  liveness do
    enabled? false   # publishes nothing, so its QuickViews are not live
  end
end
```

Topics are **never named** on either side — both come from `AshQuick.Topics`, so
a view cannot subscribe to a topic a resource does not publish. `:extra_records`
returns records or `{resource, id}` pairs rather than topics for the same reason:
`AshQuick.Topics` stays the only thing that spells a topic out.

By default the subscription is derived by walking the **fetched data** and
taking one topic per record reachable from it, the view's own rows included. A
page rendering related values goes live on them with nothing declared: an
order's details page watches the order, its lines, their products, the
customer and the address — a dozen-odd topics for a three-line order, and
nothing else in the system wakes it. Set `recursive?: false` to stop at the
rows on screen instead:

```elixir
liveness_options: [recursive?: false]
```

The walk reaches what **materialized**, so two limits follow from where the
computation happened rather than from the walk:

- An **expression calculation or aggregate** is computed in SQL and materializes
  no records (`Order.total` over the `lines_total` aggregate leaves `lines`
  unloaded), so there is no id to watch. `:extra_records` is the answer when the
  view can name the ids:

  ```elixir
  liveness_options: [extra_records: &__MODULE__.watched_records/1]
  ```

- A **newly created** related record has no id on the page yet, so a create does
  not reach it. Often covered anyway: a denormalized attribute on the parent
  (a `current_state` the child's creation writes back) means the create
  publishes the parent too.

Note that a create never adds a *row* to a list either, whatever the
subscription: `keep_live` runs with `results: :keep` and its refetch maps over
the records already on screen.

A related resource that publishes nothing is **skipped silently** — the page
just is not live on its changes, and nobody is forced to publish. Since the
topic set is data-derived and differs per actor and per row, ask the socket:

```elixir
AshQuick.LiveView.Liveness.explain(socket)
#=> %{subscribed: ["order:...", "item:...", ...],
#     skipped: %{MyApp.Sales.OrderLine => 2}}
```

Tuning liveness on a resource that publishes nothing **fails to compile** — the
options would have nothing to act on, and a page that silently never updates has
no runtime symptom, so it is refused at build time rather than shipped.

## Adding the extension to a resource

```elixir
use Ash.Resource,
  domain: MyApp.Catalog,
  extensions: [AshQuick]
```

**That one line adds columns, so it needs a migration.** Generate it and read
it before running it — `mix ash_quick.gen.resource MyApp.Catalog.Product` adds
the extension and names the columns it will cost.

| Added | When |
|---|---|
| `version` (integer, default `1`) | always, unless versioning is disabled |
| `inserted_at`, `updated_at` (`utc_datetime_usec`, `always_select?`) | unless declared `false` |
| `inserted_by_id`, `updated_by_id` (FKs to the configured `:actor_resource`) | unless declared `false` |
| `active` (boolean, NOT NULL, default `true`) | only when `activation` is declared |

Every one is **add-if-absent**: a resource that already defines the attribute
or the relationship keeps exactly what it wrote, and
`AshQuick.Bookkeeping.Verifier` refuses to compile a declaration that
disagrees with the fields in either direction. The extension also attaches the
audit change to every create/update/destroy and wires the resource's PubSub
publications.

### The sections and their defaults

All eight live under one `ash_quick do` block. **Write only what differs from
the default** — a resource that says nothing still gets liveness, versioning,
bookkeeping and auditing.

| Section | Default | Declare it to… |
|---|---|---|
| `liveness` | `enabled? true`, `prefix` = the resource's `short_name` | turn publishing off, or rename the topic prefix |
| `display` | inferred from `:display_name`, else `:name` | name the label field on a resource with neither |
| `lookup` | nothing generated; `action :index`, `search_argument :search` when written | point search at a different read action |
| `activation` | `enabled? false` | opt into soft-delete: `:active`, `:activate`/`:deactivate` |
| `versioning` | `enabled? true`, `attribute :version` | turn the optimistic lock **off** |
| `bookkeeping` | all four fields on: `:inserted_at` / `:updated_at` / `:inserted_by` / `:updated_by` | declare a field `false`, or rename it |
| `audit` | `enabled? true`, store from the configured `:audit_resource` | write elsewhere, exclude actions, or turn it off |
| `field_restrictions` | none | restrict a field to actors passing a check |

`AshQuick.Info` reads every one of them back — `display_label/1`,
`lookup_action/1`, `versioning?/1`, `activation?/1`, `bookkeeping/1`, and so on.

## Resource conventions

Most of these are compile-time refusals, not degradations — the extension's
verifiers run while the resource compiles, and the error names the resource
and what to write.

- **`extensions: [AshQuick]`** — Wires the PubSub publications liveness needs.
  The topic defaults to the resource's `short_name`; override it (and turn
  publishing off) in the resource:

  ```elixir
  ash_quick do
    liveness do
      enabled? true      # the default
      prefix "users"     # defaults to short_name
    end
  end
  ```

  Prefixes must be unique across resources, or two resources cross-wire.
  A resource may still write its own `pub_sub` block — AshQuick appends to it
  and removes nothing; only the prefix is AshQuick's to set.
- **An `:id` that addresses exactly one row** — **Required**, and checked by
  `AshQuick.Identity.Verifier`. List rows build their DOM ids from `record.id`
  and push it back over the socket to say which row was clicked; the details
  route is `/<path>/:id`. Either make it the primary key (`uuid_primary_key
  :id`) or, on a resource keyed elsewhere, declare the uniqueness it already
  has with `identity :unique_id, [:id]`. `:id` as one column of a composite
  primary key is neither — it repeats. A composite-keyed join resource should
  not carry the extension until a page needs it.

  This is about *identity*, not labelling — what a record is **called** is the
  separate `display` declaration below.

  Prefer making `:id` the primary key: the audit row records `record.id` as
  the audited record's identifier rather than resolving the declared primary
  key, so a resource keyed on something else logs the `:id` either way.
- **A lookup action** — the read action a search runs through, and the
  argument the text arrives as:

  ```elixir
  ash_quick do
    lookup do
      action :index           # the default
      search_argument :search # the default
    end
  end
  ```

  One declaration stands behind three surfaces — the list page, the export,
  and every BelongsTo/HasMany dropdown pointing **at** this resource. It lives
  on the resource because the dropdown is the case with nowhere else to put
  it: a dropdown's destination is frequently a resource with no QuickView of
  its own.

  `AshQuick.Lookup.Verifier` holds a *declared* action to three things: it
  exists, it accepts the `search_argument` (and tolerates `nil` for it), and
  it declares `pagination` — the list pages the answer and the dropdowns read
  `.results` off it, so a non-paginated action raises at the reader rather
  than at the query.

  Nothing is generated for a resource that declares none, so a join resource
  no dropdown points at is never asked for one. Absence is caught where
  reachability is known instead: a QuickView listing the resource, or one
  whose forms render a dropdown onto it, fails to compile. `list:
  [default_action: ...]` overrides the action for that one page and is held to
  the same three requirements.
- **A display label** — Required. What a record is called in detail headers,
  BelongsTo/HasMany dropdowns, print filenames and any field listing a bare
  relationship. Inferred from a `:display_name` field, else a `:name` attribute;
  name another with `ash_quick do display do label :the_field end end`. A resource
  offering neither convention **does not compile** — an id is a uuid rather than a
  label — so a resource named by nothing it stores composes one, which is what the
  rung asks for (a field, not an attribute):
  `calculate :display_name, :string, expr(string_join([order.name, product.name], " — "))`.
  See `AshQuick.Info.display_label/1`.
- **Activation** — Optional, and declared rather than detected: a resource opting in
  with `ash_quick do activation do enabled? true end end` gets an `:active` attribute,
  `:activate`/`:deactivate` actions, dimmed rows for its inactive records, activate/deactivate
  row actions, and its inactive records withheld from dropdowns onto it. A resource that merely
  *has* an `:active` column (an integration extension may put one on its connections) gets
  none of it — see `AshQuick.Info.activation/1`.
- **Versioning** — **On unless the resource declares otherwise**, the opposite of
  activation: losing a concurrent write is silent and unrecoverable, so a resource
  that does not want the optimistic lock has to say so with
  `ash_quick do versioning do enabled? false end end`. Left alone, the resource gains
  a `:version` integer counter (default `1`), every `:update`/`:destroy` is filtered
  on the version the actor loaded and bumps it, and all of them are forced to
  `require_atomic? false`. A stale write raises `Ash.Error.Changes.StaleRecord` —
  in a UI that means "someone else changed this, reload"; it is not a bug to
  suppress. Do not turn versioning off to escape the forced `require_atomic?
  false` either; that is the mechanism, not a side effect.

  **`Ash.bulk_update` therefore never takes the atomic path** on a versioned
  resource. It runs `:stream` — a real changeset, notification and audit row
  per record. Correct, and not free: size batches accordingly.

  Bookkeeping-only changes (timestamps, audit relationships) do not count as changes
  and do not bump — see `AshQuick.Config.versioning_ignored_attributes/1`.
  `attribute` names a different counter when `:version` is taken. A resource that
  already defines `:version` as something *other* than a lock counter does not
  compile (`AshQuick.Versioning.Verifier`) — an outbox extension may give its
  resources a `:version` meaning the event's *schema* version.

  **Adding a new AshQuick resource therefore adds a `version` column by default.**
  Opt out for an append-only resource, or one only a single writer ever touches.
- **Audit** — **On unless the resource turns it off.** Every create, update and
  destroy writes a row into the store, in `after_batch` **inside the action's
  transaction**: a store that refuses the batch fails the write. So keep the
  store dumb — no policies to evaluate, no validations to trip.

  There is no fallback sink, so a resource with no store resolvable (from
  `audit do store ... end`, else the configured `:audit_resource`) **does not
  compile**. A write with no actor (a background job, an integration) is
  recorded too, with `actor_id: nil` and `real_actor_id: nil`, so the store
  must allow `nil` in both. Say what made a write under `action_source` in
  the action's context — `context: %{action_source: "nightly_sync"}` — on any
  write a person did not make through a form, with an actor or without. It is a
  convention, not enforced; other top-level string or atom values are kept too,
  nested ones are not. To keep a write out of the log, use `exclude_actions` or
  turn audit off — passing no actor no longer does it.

  ```elixir
  ash_quick do
    audit do
      enabled? false                       # keep no record, and say so where a reader sees it
      exclude_actions [:refresh_cache]     # or drop just the noisy ones
      record_sensitive [:masked_card_no]   # `sensitive?` values are "**redacted**" otherwise
    end
  end
  ```

  To audit only *some* actions, turn the section off and attach the change by
  hand: `update :do_something do change AshQuick.Audit.Change end`.
- **Bookkeeping** — all four of `:inserted_at`, `:updated_at`, `:inserted_by`,
  `:updated_by` are on by default; a resource carrying the full set declares
  nothing. Declare a field `false` when the resource genuinely has none — and
  note the verifier checks **both** directions, because a real column left out
  of the declaration drops off the versioning ignore list and starts bumping
  the lock on writes that used to be no-ops.

  `:inserted_by` / `:updated_by` name **relationships**, and only a relationship
  to the configured `:actor_resource` satisfies one. A resource with its own
  `belongs_to :inserted_by, SomethingElse` declares `inserted_by false` and keeps
  it.

## Field restrictions DSL

The `ash_quick` DSL section in Ash resources controls field-level access in forms.
It works at **both** the UI layer (hides fields) and the backend (strips values
from changesets as defense in depth).

### Declaration in a resource

```elixir
ash_quick do
  field_restrictions do
    restrict :platform_roles, MyApp.FieldRestrictionChecks.ActorHasPlatformRole,
      on: [:create, :update]
  end
end
```

### Options for `restrict`

- First argument: the field name (attribute or argument)
- Second argument: a check module or `{CheckModule, opts}` tuple
- `:on` — list of action names this applies to (optional, defaults to all create/update)
- `:description` — human-readable documentation (optional)

### Writing a check module

Implement the `AshQuick.FieldRestrictions.Check` behaviour with a `match?/2` callback:

```elixir
defmodule MyApp.FieldRestrictionChecks.ActorHasPlatformRole do
  @behaviour AshQuick.FieldRestrictions.Check

  @impl true
  def match?(%{actor: %{platform_roles: roles}}, opts) when is_list(roles) do
    cond do
      :super_user in roles -> true
      opts[:role] -> Enum.member?(roles, opts[:role])
      true -> roles != []
    end
  end

  def match?(_, _), do: false
end
```

The callback receives:
- `check_context` — a `%Check.Context{actor: ..., tenant: ...}` struct
- `opts` — keyword options from the `{CheckModule, opts}` tuple (empty list if none)

### How it works

1. **UI layer**: `AshQuick.FieldRestrictions.Info.field_visible?/4` checks if the
   current actor passes the restriction. Fields that fail are hidden from forms.
2. **Backend layer**: `StripRestrictedFields` change is auto-added to the resource
   by the transformer. On create/update, it clears values for fields where the
   actor fails the check — preventing bypass via direct API calls.

### Querying field visibility at runtime

```elixir
AshQuick.FieldRestrictions.Info.field_visible?(
  MyApp.Resource,
  :update,          # action name
  :platform_roles,  # field name
  %Check.Context{actor: current_user, tenant: tenant}
)
```

## There are no companion extensions

`extensions: [AshQuick]` is the whole of it. Soft-delete and optimistic locking are
the `activation` and `versioning` sections of the `ash_quick` DSL above, not separate
extensions to list.

## Configuration

Everything lives under `config :ash_quick` in **`config/config.exs`, not
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

`:endpoint` and `:actor_resource` are `Application.compile_env/2` reads —
resources bake them in while they compile, the endpoint becoming each
resource's PubSub publications and the actor resource its `inserted_by` /
`updated_by` relationships. Put either in `runtime.exs` and a release loads it
long after the resources were built against `nil`, with no runtime symptom: the
pages are simply dead and the columns empty. `mix igniter.install ash_quick`
writes this block in the right file; `AshQuick.Config` documents every key.

`:error_translator` renders every Ash error message AshQuick shows, flash and
form alike. Hosts put Ash's own messages in their catalogue with `mix
ash.gen.gettext --domain errors` (the installer prints this, and changes no
`priv/gettext` file). A form shows a field error under its input when it has
one for that field, and flashes it as `Field: message` when it has not. A
policy's `error_message` is what a run it refuses flashes, translated like any
msgid (add it to the `errors` catalogue); without one, or when the
`error_message` function returns its own exception, the flash is "You don't
have permission to do that." Give a policy an `error_message` when the person
refused can act on the reason.

## What the host application provides

AshQuick reaches into the host through these and nothing else. `deps/ash_quick/README.md`
covers wiring them up.

- `AshQuick.Scope` — `use` it on the host's scope struct. Generates
  `Ash.Scope.ToOpts` plus the provenance audit needs: real actor behind an
  impersonation, request IP, timezone, locale.
- **The audit store** — an Ash resource taking `resource_name`, `resource_id`,
  `action_type`, `action_name`, `attributes`, `arguments`, `context`,
  `actor_id`, `real_actor_id`, `ip`, `tenant`, and optionally a `:map`
  `changes` (what each attribute was and became).
- `AshQuick.Storage` — object storage; defaults to `AshQuick.Storage.S3`.
- `AshQuick.AccessControl` — which routes a scope may navigate to. Named on the
  nav. Deliberately **not** `Ash.can?`: a filter policy allows the action and
  returns no rows, so `can?` says yes for a page that would be empty.
- `AshQuick.Nav` — the navigation registry (see Navigation above).
- `AshQuick.PrintTemplate`, `AshQuick.FieldRestrictions.Check` — print
  templates and field-level checks. A create or update action prints through a
  template with `change {AshQuick.Print, template: MyTemplate, delivery: :print}`
  (`:download` is the default): run from a row, a bulk selection, the details
  page or its form, the PDF is rendered after the action commits and goes over
  the socket to `assets/js/print.js`'s `initPrinting/0`, which the host's
  `app.js` calls once. On a resource carrying the `AshQuick` extension, a
  print on a destroy, with bad options, or without `chromic_pdf` in the deps
  (and no `:pdf_renderer` of the host's own) does not compile
  (`AshQuick.Print.Verifier`); on any other resource the same mistakes surface
  when the action runs. `config :ash_quick, pdf_renderer:` names an
  `AshQuick.PdfRenderer` to render with instead of ChromicPDF: a test suite
  with no Chrome uses one that hands back the template's HTML, and asserts on
  the `"ash_quick:pdf"` push event. A template that writes nothing
  prints from an update with
  `manual fn changeset, _context -> {:ok, changeset.data} end`.
- `AshQuick.BrowserSessionPresence` in the supervision tree, and
  `AshQuick.LiveView.Mount` **first** in the live session's `on_mount`.
- In `app.js`: `browserSessionParams` / `initBrowserSession` and `initLocale`
  from `deps/ash_quick/assets/js/`, and the library's colocated hooks
  (`import { hooks as ashQuickHooks } from "phoenix-colocated/ash_quick"`,
  spread into the LiveSocket's `hooks`). The hooks are written under
  `Mix.Project.build_path()` when AshQuick compiles, so esbuild's `NODE_PATH`
  must include it (a Phoenix 1.8 app's does) and `mix compile` must run before
  the asset build. In `app.css`: the `@source` line for the library's classes
  and the `phx-submit-loading` variant the modal's spinner and lock hang on.

## Checking the application

`mix ash_quick.check` reports what a Spark verifier structurally cannot see: it
looks at one resource's DSL, so it cannot catch a fact spanning two resources,
and it knows nothing about the router.

```console
$ mix ash_quick.check           # report, exit 0
$ mix ash_quick.check --strict  # exit 1 on any defect, for CI
```

Two resources on one liveness prefix; a QuickView routed by hand; a control
leading to a route `:only`/`:except` left out; every way a nav, a router and an
access control can disagree. Plus one advisory — a resource with no extension —
which reports on every run and fails nothing.

Run it after adding a resource, a route or a nav entry. The nav/access-control
half needs the optional `AshQuick.AccessControl.all_routes/0` — without it those
checks are reported as *not run* rather than passing.

It does **not** ask a resource to justify `versioning enabled? false` or
`audit enabled? false`, and does not require a lookup action. Record a
divergence you mean to keep with

```elixir
config :ash_quick,
  check: [exempt: [unroutable_action: ["/file_objects/:id/reference"]]]
```

`AshQuick.Check` names every check and what it keys an exemption on.

## Common mistakes

- Routing a QuickView with `live/3` instead of `quick_view/3`.
- Reading `:only` / `:except` as resource action names. They are route shapes.
- Turning versioning off to escape the forced `require_atomic? false`, or
  rescuing `StaleRecord` instead of surfacing it.
- Narrowing a `quick_view` past `:show` or `:action` while the page still
  renders controls leading there. Rows link to `<base>/<id>`, and every update
  or destroy, with inputs or without, opens at `<base>/<id>/<action>`.
- Giving two resources the same liveness `prefix`. Their pages cross-wire, and
  no verifier can see it — `mix ash_quick.check` can.
- Adding the extension without generating a migration for the new columns.
- Putting `:endpoint` or `:actor_resource` in `runtime.exs`.
- A bare `Ash.can?/2` in a custom template, so the control ignores
  surface-scoped policies — or a record-less probe where a record exists.
- Hiding a control with a policy and stopping there, with no validation behind
  it — a surface-scoped policy never refuses the run.
- Selecting `"form"` in a LiveView test of an action. The page underneath the
  modal is in the DOM too; select `"#ash-quick-action-modal form"`.
- Adding a public function to `AshQuick.Components`: every QuickView imports
  it, so it can collide with a host helper of the same name.
- Declaring `:filters` as a map keyed by atoms. It is a **list of string-keyed
  maps**.
- Putting the extension on a composite-keyed join resource.
- Naming a relationship in `display do label ... end`. It holds a struct;
  compose a calculation instead.

## Key source files

- `deps/ash_quick/lib/ash_quick/liveview/quick_view.ex` — Main macro and moduledoc
- `deps/ash_quick/lib/ash_quick/liveview/list_utils.ex` — List view logic
- `deps/ash_quick/lib/ash_quick/liveview/details_utils.ex` — Detail view logic
- `deps/ash_quick/lib/ash_quick/liveview/form_utils.ex` — Form logic
- `deps/ash_quick/lib/ash_quick/liveview/bulk_actions.ex`, `bulk_form.ex` — the bulk menu and the record-less bulk form
- `deps/ash_quick/lib/ash_quick/print.ex`, `print_template.ex`, `liveview/print_utils.ex` — printing
- `deps/ash_quick/lib/ash_quick/components.ex` — UI components (icon, label, button, header, simple_form, input) and the `SubmitLock` hook
- `deps/ash_quick/lib/ash_quick/liveview/components/` — ListView, DetailsView, FormView, ActionModal, BulkActionView, Sidebar, NavGrid, FilterForm
- `deps/ash_quick/lib/ash_quick/nav.ex`, `deps/ash_quick/lib/ash_quick/nav/` — The nav DSL, its verifier, and the resolution the sidebar and grid render
- `deps/ash_quick/lib/ash_quick/config.ex` — every `config :ash_quick` key, documented
- `deps/ash_quick/lib/ash_quick/check.ex`, `deps/ash_quick/lib/ash_quick/check/` — every check `mix ash_quick.check` runs
- `deps/ash_quick/lib/ash_quick.ex` — the extension: every `ash_quick do` section, and `AshQuick.can?/4`
- `deps/ash_quick/lib/mix/tasks/` — the installer and the two generators
- `deps/ash_quick/README.md` — installing and wiring it into a host application
