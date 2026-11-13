defmodule Example.Test.AtomicBrand.Domain do
  @moduledoc "Holds the brand resource whose updates run atomically."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.AtomicBrand do
  @moduledoc """
  `Example.Catalog.Brand`'s table, written through named actions that keep
  Ash's default `require_atomic? true`.

  `Example.Catalog.Brand` has only default actions, which Ash never requires to
  be atomic, so its writes always take the in-memory path. These take the
  atomic one — one `UPDATE` with the lock worked out inside it — or fail with
  `Ash.Error.Framework.MustBeAtomic`, so a write that lands here is one the
  lock decided in `atomic/3`, on PostgreSQL.

  Everything else is the extension's defaults, as on the real resource:
  versioning, audit and the bookkeeping stamps, which the lock ignores. Its
  upserts on `:code` are the real resource's identity, written over atomically
  in PostgreSQL's `ON CONFLICT`. The
  `read_only_fields` block keeps `:code` an admin's on `:rename`, so a
  read-only field is driven on the atomic path too.
  """
  use Ash.Resource,
    domain: Example.Test.AtomicBrand.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshQuick]

  postgres do
    table "brands"
    repo Example.Repo
  end

  actions do
    # Rows are created through `Example.Catalog.Brand`, so they are the real
    # resource's rows seen through atomic actions.
    defaults [:read]

    read :index do
      argument :search, :string

      pagination do
        keyset? true
        offset? true
        default_limit 20
        countable :by_default
      end
    end

    update :rename, accept: [:code, :name]

    update :shout do
      accept []
      change atomic_update(:name, expr(name <> "!"))
    end

    destroy :remove

    # An import matching on the natural key: on a conflict the row is written
    # over with `name`.
    create :upsert do
      accept [:code, :name]
      upsert? true
      upsert_identity :code
      upsert_fields [:name]
    end

    # Ash's widest `upsert_fields`: every attribute the create sets, the
    # counter's default included.
    create :upsert_all do
      accept [:code, :name]
      upsert? true
      upsert_identity :code
      upsert_fields :replace_all
    end
  end

  ash_quick do
    display do
      label :name
    end

    liveness do
      enabled? false
    end

    read_only_fields do
      read_only :code, writable_if: Example.Checks.RoleIsAdminOnly, on: [:rename]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
  end

  identities do
    identity :code, [:code]
  end
end

defmodule Example.Test.AtomicBrandLive.Quick do
  @moduledoc """
  The page over `Example.Test.AtomicBrand`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`. Its row menu offers the
  atomic `:rename`, so a stale form save is driven down the atomic path.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.AtomicBrand,
    list: [fields: [:code, :name]],
    details: [fields: [:code, :name]]
end
