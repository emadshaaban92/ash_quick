# AshQuick usage rules

AshQuick is two things that fit together: a Spark extension (`extensions:
[AshQuick]`) that gives an Ash resource an identity, a lock, bookkeeping and an
audit trail, and a LiveView generator (`use AshQuick.LiveView.QuickView`) that
renders list, details, create and update pages from it.

Rules first, reasoning in the moduledocs — `AshQuick` for every DSL section,
`AshQuick.LiveView.QuickView` for every view option, `AshQuick.Config` for
every configuration key.

## Adding the extension to a resource

```elixir
use Ash.Resource,
  domain: MyApp.Catalog,
  extensions: [AshQuick]
```

**This adds columns, so it needs a migration.** `version` (integer, default
`1`) unless versioning is disabled; `created_at`, `updated_at`,
`created_by_id`, `updated_by_id` unless declared `false`; `active` only if
activation is declared. Every one is add-if-absent — a resource that already
defines the attribute or relationship keeps exactly what it wrote. Generate the
migration and read it.

It also attaches the audit change to every create/update/destroy and wires the
resource's PubSub publications.

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
| `bookkeeping` | all four fields on, `:created_at` / `:updated_at` / `:created_by` / `:updated_by` | declare a field `false`, or rename it |
| `audit` | `enabled? true`, store from `:audit_resource` | write elsewhere, exclude actions, or turn it off |
| `field_restrictions` | none | restrict a field to actors passing a check |

`AshQuick.Info` reads every one of them back (`display_label/1`,
`lookup_action/1`, `versioning?/1`, `activation?/1`, `bookkeeping/1`, …).

### Three things a resource must satisfy

Each is a compile-time refusal, and the error names the resource and what to
write. Do not work around them — they are the contract the views depend on.

**1. An `:id` that addresses exactly one row.** List rows build their DOM ids
from `record.id` and push it back over the socket to say which row was clicked;
details is `/<path>/:id`. Either `uuid_primary_key :id`, or — on a resource
keyed elsewhere — `identity :unique_id, [:id]`. `:id` as one column of a
composite primary key is neither; it repeats. Do not put the extension on a
composite-keyed join resource until a page actually needs it.

Prefer `:id` as the primary key: the audit row records `record.id` as the
audited record's identifier rather than resolving the declared primary key.

**2. A display label** — what a record is *called*, wherever AshQuick has to
name one it was not written against: a relationship dropdown option, a details
header, a print filename, any field listing a bare relationship. Inferred from
`:display_name` or `:name`. A resource with neither **does not compile** —
falling back to a uuid would answer "nobody has said what this is called" with
something that only looks like an answer.

```elixir
ash_quick do
  display do
    label :code
  end
end
```

`label` names an attribute, calculation or aggregate — never a relationship
(it holds a struct) and never an expression. Compose a label in a calculation
and name that:

```elixir
calculate :display_name, :string, expr(string_join([order.name, product.name], " — "))
```

This is separate from rule 1: `:id` is identity, `display` is labelling.

**3. A lookup action**, if anything searches the resource. One declaration
stands behind three surfaces — the list page, its export, and every
BelongsTo/HasMany dropdown pointing **at** this resource. It lives on the
resource because a dropdown's destination is often a resource with no QuickView
of its own.

```elixir
ash_quick do
  lookup do
    action :index           # the default
    search_argument :search # the default
  end
end
```

A declared action must exist, accept the `search_argument` (and tolerate `nil`
for it), and declare `pagination` — the list pages the answer and dropdowns
read `.results` off it. Nothing is generated for a resource that declares none,
so a join resource nothing searches is never asked; absence is caught instead
where reachability is known, when a QuickView listing it (or rendering a
dropdown onto it) compiles.

## Versioning is on by default — know what it does

Unless the resource says otherwise, every `:update` and `:destroy` is filtered
on the `version` the actor loaded and bumps it.

- **`require_atomic? false` is forced on every `:update` and `:destroy`.** The
  lock is decided in a `before_action` against the final changeset, and
  reaching it needs the non-atomic path. Do not "fix" the resulting compile
  behaviour by turning versioning off.
- **`Ash.bulk_update` therefore never takes the atomic path.** It runs
  `:stream` — a real changeset, notification and audit row per record. Correct,
  and not free: size batches accordingly.
- **`Ash.Error.Changes.StaleRecord` is a live failure mode.** Every caller of an
  update handles it. In a UI it means "someone else changed this, reload"; it is
  not a bug to be suppressed.
- A genuine no-op update neither bumps nor filters, and changes confined to the
  bookkeeping fields do not count as changes
  (`AshQuick.Config.versioning_ignored_attributes/1`).

**Turn it off only when there is nothing to lose** — an append-only log, a row
a single writer ever touches:

```elixir
ash_quick do
  versioning do
    enabled? false
  end
end
```

A resource that defines `:version` meaning something else (an event's *schema*
version, say) does not compile — `attribute` names a different counter, or
`enabled? false`.

## QuickView

```elixir
defmodule MyAppWeb.ProductLive.Quick do
  use AshQuick.LiveView.QuickView,
    resource: MyApp.Catalog.Product,
    list: [fields: [:code, :name, :price], new_action_label: "Add Product"],
    details: [fields: [:code, :name, :description, :price, :created_at]]
end
```

`:resource` is the only required option. **The URL is not an option** — it is
declared once in the router and arrives as `@base_path`.

### Routing

Route a QuickView with `AshQuick.LiveView.Router.quick_view/3` and nothing
else. A QuickView reached through a hand-written `live/3` has no base path and
raises at request time.

```elixir
import AshQuick.LiveView.Router

quick_view "/products", MyAppWeb.ProductLive.Quick
```

That declares four routes: `/products`, `/products/create`, `/products/:id`,
`/products/:id/:action`. `:only` and `:except` select from those four **shapes**
— `:index`, `:create`, `:show`, `:action`. **They never name resource actions:**
one `/:id/:action` route serves every action the resource has, so adding an
action never means touching the router.

```elixir
quick_view "/audit_logs", MyAppWeb.AuditLogLive.Quick, only: [:index, :show]
quick_view "/items", MyAppWeb.ItemLive.Quick, except: [:create]
```

Dropping `:create` keeps a resource that only ever comes from the system out of
the "New" flow. Set the layout on the `live_session`; QuickView sets none.

### Field formats

A field is a **path** or a **`{path, opts}`** tuple. A path is an atom
(`:name`) or a relationship navigation (`[category: :name]`).

```elixir
:name                                        # attribute
[category: :name]                            # relationship path
:category                                    # bare relationship → its display label
{:name, label: "Full Name"}
{:state, widget: &__MODULE__.state_widget/1}
{[category: :name], label: "Category"}
```

Opts are `:label` and `:widget`. **Prefer `{path, opts}` over the legacy
`{path, "label"}` form.** A bare relationship renders the destination's display
label, so spell out a path only when you want some other field.

### Widgets

A widget is a user-defined function component, not a library. It receives
assigns with `@value` already resolved off the record and returns HEEx. Must be
a function capture. Works in list and details.

```elixir
list: [fields: [:name, {:state, widget: &__MODULE__.state_widget/1}]]

def state_widget(assigns) do
  ~H"""
  <span class={["badge badge-sm", badge_class(@value)]}>{Utils.humanize(@value)}</span>
  """
end
```

Form widgets are different: they are a **map keyed by field name** under
`form: [widgets: %{...}]`, because a form's fields come from the action's
accepted attributes and arguments rather than a configurable list. A form
widget overrides rendering only — it cannot add a field the action does not
take. Create and update share one map; branch on `@form.action`.

### Loading

`:load` at three levels, combined: top-level (every query), `list: [load: ...]`,
`details: [load: ...]`. Put heavy relationship loads in `details`, not
top-level. Load anything a custom template, widget or event handler reads
beyond the declared `:fields`.

### Lifecycle hooks

Two overridable private functions:

```elixir
defp after_mount(socket, _options), do: socket
defp after_handle_params(socket, _options), do: socket
```

`after_mount` adds assigns after mount. `after_handle_params` runs per action —
redirect, add assigns, branch on `socket.assigns.path`. Always keep a
catch-all clause. Custom `handle_event/3` clauses may be defined alongside.

### Custom action templates

`action_<name>.html.heex` beside the QuickView module replaces the generic view
for that action. Assigns: `@record`, `@resource`, `@params`, `@scope`,
`@options`. `AshQuick.Components` is imported and `Phoenix.LiveView.JS`
aliased. To use host components, `import` them **before** `use
AshQuick.LiveView.QuickView`.

### Gating controls

QuickView renders a control only when `Ash.can?` allows it. **In a custom
template, probe with `AshQuick.can?/4`, not a bare `Ash.can?/2`** — it stamps
`action_source` so surface-scoped policies apply:

```elixir
<.button :if={AshQuick.can?({@record, :approve}, @scope, :ash_quick_details)} ...>
```

Sources are `:ash_quick_details`, `:ash_quick_list`, `:ash_quick_list_bulk`.
Pass the **record** whenever there is one: a record-less probe gives a filter
check no row and can answer `false` for a record the policy would have allowed.
An action the resource does not define answers `false` rather than raising.

A form submit is stamped `:ash_quick_form`, deliberately **not** a surface
source — a policy scoped to the three above never fires at submit, so a stale
or forged submit routes to the action's own validation (409/422) rather than a
`Forbidden`. **A state gate therefore needs both:** the policy hides the button,
an always-on validation refuses the write off-surface.

### Filters

`:filters` is a **list of maps with string keys**, rendered as toggle buttons
above the list. The expression is anything `Ash.Query.filter/2` takes,
including a raw expression over a relationship path:

```elixir
filters: [
  %{"name" => "needs_review", "label" => "Needs review",
    "expression" => Ash.Expr.expr(state == :pending or latest_request.state == :pending)},
  %{"name" => "active", "label" => "Active", "expression" => %{"active" => %{"eq" => true}}}
]
```

### Real-time updates

**A QuickView is live when its resource publishes. There is nothing to declare
on the view** — `ash_quick do liveness do ... end end` on the resource is the
whole switch. Topics are never named on either side; both come from
`AshQuick.Topics`, so a view cannot subscribe to something the resource does
not publish.

By default the subscription is derived by walking the fetched data, one topic
per record reachable from it — so a page goes live on the related values it
renders with nothing declared. `liveness_options: [recursive?: false]` stops at
the rows on screen.

The walk reaches what **materialized**. An expression calculation or aggregate
is computed in SQL and materializes no record, so use `:extra_records` (returns
records or `{resource, id}` pairs — never topics). A newly created related
record has no id on the page yet. A create never adds a *row* to a list either:
the refetch maps over the records already on screen.

Tuning `liveness_options` on a resource that publishes nothing **fails to
compile**. `AshQuick.LiveView.Liveness.explain(socket)` reports what a live
socket actually subscribed to and what it skipped.

## What the host application provides

Each is a behaviour, a resource, or a config key — AshQuick reaches into the
host through nothing else. See `README.md` for wiring them up.

- `AshQuick.Scope` — `use` it on the host's scope struct. Generates
  `Ash.Scope.ToOpts` plus the provenance audit needs: real actor, IP, timezone,
  locale.
- The audit store — an Ash resource taking `resource_name`, `resource_id`,
  `action_type`, `action_name`, `attributes`, `arguments`, `context`,
  `actor_id`, `real_actor_id`, `ip`, `tenant`. Keep it dumb: it is written
  inside the transaction of every audited write.
- `AshQuick.Storage`, `AshQuick.AccessControl`, `AshQuick.Nav`,
  `AshQuick.PrintTemplate`, `AshQuick.FieldRestrictions.Check` — object
  storage, route access, navigation, print templates, field-level checks.
- `AshQuick.BrowserSessionPresence` in the supervision tree;
  `AshQuick.LiveView.Mount` **first** in the live session's `on_mount`.

## Common mistakes

- Routing a QuickView with `live/3` instead of `quick_view/3`.
- Reading `:only`/`:except` as resource action names. They are route shapes.
- Turning versioning off to escape `require_atomic? false`, or rescuing
  `StaleRecord` instead of surfacing it.
- Adding the extension without generating a migration for the new columns.
- Putting `:endpoint` or `:actor_resource` in `runtime.exs`. Both are
  `compile_env` reads; resources bake them in. They belong in `config.exs`.
- A bare `Ash.can?/2` in a custom template, so the control ignores
  surface-scoped policies.
- Hiding a control with a policy and stopping there, with no validation behind
  it.
- Declaring `:filters` as a map of atoms. It is a list of string-keyed maps.
- Putting the extension on a composite-keyed join resource.
