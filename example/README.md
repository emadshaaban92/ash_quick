# AshQuick example app

A small Phoenix + AshPostgres application that hosts
[AshQuick](https://github.com/emadshaaban92/ash_quick) from the checkout it
lives in (`{:ash_quick, path: ".."}`).

It exists to be a **host**. The library has no Repo, no endpoint and no router,
so its own suite runs on ETS and cannot reach the paths that only exist inside a
real application:

* the optimistic lock's `before_action` filter being honoured by **AshPostgres**,
* the audit row being written **inside the transaction** of the write it records,
  so a store that refuses takes the record back with it,
* a presign **taking custody** of an arriving object through the storage seam,
* a QuickView **rendered end to end** behind a session: the list, the generated
  form, a row action, and a control the policy forbids simply not being there.

Everything it demonstrates is a by-product of that — which is also why it is
kept small enough that a failing test names one thing.

## Running it

Needs PostgreSQL 16+ reachable as `db` with an `admin`/`admin` superuser (see
`config/dev.exs`).

```console
$ mix setup          # deps, database, assets, seed data
$ mix phx.server     # http://localhost:4000
```

Sign in at `/login` — there are no passwords, just five seeded users:

| User | Role | Store | Sees |
|---|---|---|---|
| `admin@example.test` | `:admin` | — | everything, including impersonation and the audit log |
| `editor@example.test` | `:editor` | — | the catalog and the upload register; no users, no audit log |
| `viewer@example.test` | `:viewer` | — | the catalog, read-only |
| `nora@example.test` | `:editor` | Northwind Online | that shop's products, and no others |
| `sam@example.test` | `:editor` | Southgate Supply | that shop's products, and no others |

Signing in as each in turn is the quickest way to see what
`ExampleWeb.AccessControl` and the resources' policies do to a page: the apps
grid, the sidebar, the "New" button and the row actions all change with the
role, and none of that is written in a view.

The last two are the multitenancy. Same role, same page, different rows — and
nothing on `/products` mentions a store. `Example.Scope` carries the reader's
store as the Ash tenant and `Catalog.Product` declares `multitenancy` over it;
a reader who belongs to no store sees every shop's products, which is what
`global? true` on that resource is for.

`mix ash.reset` drops, recreates and re-seeds.

## Running the tests

```console
$ mix test
```

`test/ash_quick/` holds the library's host-bound tests — versioning, the audit
transaction, the presign — and `test/example_web/` the scenarios: a QuickView
driven the way a person drives it, per role, across nav and access control,
activation, the details page, forms and the optimistic lock, impersonation,
liveness, locale, bulk actions, list mechanics and export, uploads, and tenant
isolation. They are the library's real test suite; there is no router, endpoint
or session inside the package for any of it to run against.

`ExampleWeb.FeatureCase` is what they are written on — `PhoenixTest` plus the
few helpers a QuickView needs driving (`ExampleWeb.QuickViewHelpers`) and the
browser-tab identity impersonation is resolved per
(`ExampleWeb.Sessions`).

## What is wired where

| Seam | Here |
|---|---|
| `AshQuick.Scope` | `Example.Scope` — actor, real actor, impersonation flag, request IP, locale and tenant. |
| Audit store | `Example.Accounts.AuditLog`, named app-wide as `:audit_resource`. |
| `AshQuick.Storage` | `Example.Uploads.ObjectStore` — its own bucket, plus all three lifecycle callbacks, holding arriving objects in `Example.Uploads.Quarantine`. |
| `AshQuick.AccessControl` | `ExampleWeb.AccessControl` — one route list per role. |
| `AshQuick.Nav` | `ExampleWeb.Nav` — the sidebar and the apps grid. |
| Actor resource | `Example.Accounts.User`, which is why `:impersonate` is generated onto it. |
| Field restriction check | `Example.Checks.RoleIsAdminOnly`, over the user's `:role`. |

The resources cover the shapes a page has to render: a plain record
(`Catalog.Brand`), a self-referencing tree with a private attachment
(`Catalog.Category`), a record with relationships, `Money`, long text, an array
of atoms and an array of embedded attachments (`Catalog.Product`), and an
append-only log carrying only half the bookkeeping declaration
(`Catalog.PriceChange`). `Catalog.Store` is the odd one out: the tenant the
others are partitioned by rather than a shape to render, and so not multitenant
itself.

## Deliberate omissions

* **No authentication library.** A `user_id` in the session is all
  `ExampleWeb.UserAuth` reads. Authentication is the host's problem and a real
  one would only obscure the seams this app is here to show.
* **No `chromic_pdf`.** Printing would want a Chrome on the machine;
  `AshQuick.Config.print_enabled?/0` leaves the print control out without it,
  which is the behaviour worth showing. Export *is* enabled (`exceed`,
  `nimble_csv`, `briefly`), so every list has a working Excel/CSV menu.
* **Nothing releases a quarantined object on a schedule.** There is no worker
  and no scanner here; `Example.Uploads.ObjectStore.release!/1` is the seam a
  real host's pipeline would call.
* **No `config/runtime.exs`.** This app is a test host and a local demo; it is
  never deployed.
