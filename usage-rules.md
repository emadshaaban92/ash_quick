# AshQuick usage rules

AshQuick is two things that fit together: a Spark extension (`extensions:
[AshQuick]`) giving an Ash resource an identity, an optimistic lock,
bookkeeping and an audit trail, and a LiveView generator (`use
AshQuick.LiveView.QuickView`) rendering list, details, create and update pages
from it.

**The rules live in the `ash-quick` agent skill this package ships**, at
`deps/ash_quick/usage-rules/skills/ash-quick/SKILL.md`. Enable it by listing
the package in your `mix.exs`:

```elixir
usage_rules: [
  skills: [
    location: ".claude/skills",
    package_skills: [:ash_quick]
  ]
]
```

Then `mix usage_rules.sync` writes it to `.claude/skills/ash-quick/SKILL.md`.
It covers routing, navigation, view options, field and widget formats, loading,
lifecycle hooks, custom action templates, control gating, filters, real-time
updates, every `ash_quick do` section with its default, the conventions a
resource must satisfy, configuration, the host seams, and the common mistakes.

That file is the single source — this one deliberately does not restate it, so
the two cannot drift. Read it directly if you are not using skills.

## If you read nothing else

Three things bite hardest, and each is cheapest to know before you write the
resource rather than after.

**`extensions: [AshQuick]` adds columns, so it needs a migration.** `version`,
`created_at`, `updated_at`, `created_by_id`, `updated_by_id` — and `active` if
activation is declared. All add-if-absent: a resource that already defines one
keeps what it wrote.

**Versioning is on by default.** Every `:update` and `:destroy` is filtered on
the `version` the actor loaded and bumps it, which forces `require_atomic?
false` on all of them — so `Ash.bulk_update` never takes the atomic path, and
`Ash.Error.Changes.StaleRecord` is a live failure mode every caller handles.
Turn it off only where there is nothing to lose: an append-only log, a row a
single writer touches.

**Three things refuse to compile.** An `:id` that addresses exactly one row
(the views build DOM ids from it and route on it); a display label, inferred
from `:display_name` or `:name` and otherwise declared; and, wherever something
searches the resource, a lookup action that accepts the search argument and
declares `pagination`.

## Check the application, do not eyeball it

`mix ash_quick.check` reports what a resource verifier structurally cannot see:
two resources sharing a liveness prefix, a QuickView routed by a plain `live/3`,
a control leading to a route `:only` or `:except` left out, and every way a nav,
a router and an access control can disagree about a path. A resource carrying no
extension at all is reported too, as an advisory.

Run it after adding a resource, a route or a nav entry. `--strict` fails on
defects and never on advisories. Record a divergence you mean to keep with
`config :ash_quick, check: [exempt: [...]]` rather than remembering it.

## Reference

The moduledocs carry the reasoning, and are the place to check an exact
signature or option:

- `AshQuick` — every `ash_quick do` section, and `AshQuick.can?/4`
- `AshQuick.LiveView.QuickView` — every view option
- `AshQuick.LiveView.Router` — `quick_view/3` and the four route shapes
- `AshQuick.Config` — every `config :ash_quick` key
- `AshQuick.Check` — every check `mix ash_quick.check` runs
- `README.md` — installing and wiring it into a host application
