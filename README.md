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

## Installation

```elixir
def deps do
  [{:ash_quick, github: "emadshaaban92/ash_quick"}]
end
```

Configuration lives under the `:ash_quick` key in `config/config.exs` — not
`runtime.exs`, because `:endpoint` and `:actor_resource` are read at compile
time and resources bake their publications and actor relationships from them:

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

`AshQuick.Config` documents every key.

Two asset lines, so QuickViews are styled and each browser tab carries its own
session:

```css
/* assets/css/app.css */
@source "../../deps/ash_quick/lib/**/*.*ex";
```

```javascript
// assets/js/app.js
import { browserSessionParams, initBrowserSession } from "../../deps/ash_quick/assets/js/browser_session"
import { initLocale } from "../../deps/ash_quick/assets/js/locale"
```

And `:ash_quick` in `.formatter.exs`'s `import_deps`, so the DSL formats
without parens.

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

## Status

Extracted from a production application. A fuller adoption guide — resource
conventions, what the extension adds, routing — is being written.
