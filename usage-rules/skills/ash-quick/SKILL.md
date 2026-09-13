---
name: ash-quick
description: "Use this skill when working with AshQuick — the declarative CRUD LiveView system for Ash resources. Load it when a module has `use AshQuick.LiveView.QuickView`, when a resource carries `extensions: [AshQuick]` or an `ash_quick do` block, when a router uses `quick_view/3`, or when hitting `Ash.Error.Changes.StaleRecord` on an update. Covers QuickView configuration, field formats, widgets, lifecycle hooks, custom action templates, navigation, filters, bulk actions, real-time updates, and the conventions a resource must satisfy."
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
      fields: [:code, :name, :description, :price, :quantity, :created_at]
    ]
end
```

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
would be a cycle) and it knows nothing of roles. So the host writes one test
over the assembled application, reconciling router, nav and access control:
a nav path no route serves, a granted route no entry renders, a granted route
no group gives a tile, and a nav entry no role can reach should each fail there
by name. Without that test those four are silent.

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
- `:print_templates` — Modules implementing `AshQuick.PrintTemplate`
- `:export_fields` — Fields for Excel/CSV export

### List options (`:list`)
- `:fields` — Fields in the list table
- `:load` — Extra loads for list queries only
- `:default_action` — Read action for listing (default `:index`)
- `:new_action_label` — Label for "Create" button
- `:bulk_actions` — `fn socket -> [...] end` for custom bulk actions

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
- `id: nil` + create action -> **Create form**
- `id: <uuid>` + update action -> **Edit form**

Action resolved from (priority order):
1. `action` URL parameter
2. `live_action` from router (e.g. `:create`)
3. Configured default action

## Custom action templates

Place `action_<name>.html.heex` in the same directory as the QuickView module:

```
lib/my_app_web/live/orders/
  quick.ex                    # QuickView module
  action_read.html.heex       # Custom details template for :read
```

Template has access to: `@record`, `@resource`, `@params`, `@scope`, `@options`.
`AshQuick.Components` is imported and `Phoenix.LiveView.JS` is aliased.

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
- A form submit is stamped `:ash_quick_form`, deliberately **not** one of the
  three surface sources. A policy scoped to those never fires at submit, so a
  stale or forged submit routes to the action's own validation (409/422)
  instead of a `Forbidden`. **A state gate therefore needs both**: the policy
  hides the button, and an always-on validation refuses the write off-surface.
  A policy alone leaves the action open to anyone posting the event; a
  validation alone renders a button that always errors.

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
  `require_atomic? false`. A stale write raises `Ash.Error.Changes.StaleRecord`.
  Bookkeeping-only changes (timestamps, audit relationships) do not count as changes
  and do not bump — see `AshQuick.Config.versioning_ignored_attributes/1`.
  `attribute` names a different counter when `:version` is taken. A resource that
  already defines `:version` as something *other* than a lock counter does not
  compile (`AshQuick.Versioning.Verifier`) — an outbox extension may give its
  resources a `:version` meaning the event's *schema* version.

  **Adding a new AshQuick resource therefore adds a `version` column by default.**
  Opt out for an append-only resource, or one only a single writer ever touches.

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

## Key source files

- `deps/ash_quick/lib/ash_quick/liveview/quick_view.ex` — Main macro and moduledoc
- `deps/ash_quick/lib/ash_quick/liveview/list_utils.ex` — List view logic
- `deps/ash_quick/lib/ash_quick/liveview/details_utils.ex` — Detail view logic
- `deps/ash_quick/lib/ash_quick/liveview/form_utils.ex` — Form logic
- `deps/ash_quick/lib/ash_quick/components.ex` — UI components (icon, label, button, header, simple_form, input)
- `deps/ash_quick/lib/ash_quick/liveview/components/` — ListView, DetailsView, FormView, Sidebar, NavGrid, FilterForm
- `deps/ash_quick/lib/ash_quick/nav.ex`, `deps/ash_quick/lib/ash_quick/nav/` — The nav DSL, its verifier, and the resolution the sidebar and grid render
- `deps/ash_quick/lib/ash_quick/config.ex` — every `config :ash_quick` key, documented
- `deps/ash_quick/lib/ash_quick.ex` — the extension: every `ash_quick do` section, and `AshQuick.can?/4`
- `deps/ash_quick/README.md` — installing and wiring it into a host application
