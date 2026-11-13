defmodule AshQuick.Test.VersioningDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshQuick.Test.Ledger do
  @moduledoc """
  A versioned resource whose named updates run atomically.

  Nothing here says `require_atomic? false`, and versioning no longer turns it
  off, so `:rename`, `:bump` and `:retitle` go down Ash's atomic path and
  `AshQuick.Versioning.Lock` decides there, in `atomic/3`. `:rename_in_memory`
  is the same write on the in-memory path, for the two to be held side by side.

  `updated_at` is bookkeeping, which the lock ignores, so a write that moves
  nothing but it is a no-op as far as the version is concerned.
  """
  use Ash.Resource,
    domain: AshQuick.Test.VersioningDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :note, :string, public?: true
    attribute :count, :integer, public?: true, allow_nil?: false, default: 0
  end

  actions do
    default_accept [:name, :note]
    defaults [:read, :create]

    update :rename, accept: [:name, :note]

    update :bump do
      accept []
      change atomic_update(:count, expr(count + 1))
    end

    # The value comes from a change rather than from input, so on the atomic
    # path it is an expression the lock cannot read before the row does.
    update :retitle do
      accept []
      argument :title, :string, allow_nil?: false
      change atomic_update(:name, expr(^arg(:title)))
    end

    update :rename_in_memory do
      accept [:name, :note]
      require_atomic? false
      change fn changeset, _context -> changeset end
    end

    destroy :remove
  end

  ash_quick do
    display do
      label :name
    end

    liveness do
      enabled? false
    end

    audit do
      enabled? false
    end

    bookkeeping do
      inserted_at false
      inserted_by false
      updated_by false
    end
  end
end

defmodule AshQuick.Test.ImportedLedger do
  @moduledoc """
  A versioned resource written by upserts on a natural key, the way an import
  is.

  A resource of its own because on ETS an identity is checked in a
  `before_action`, which would keep `AshQuick.Test.Ledger`'s updates off the
  atomic path. `:rename` here runs in memory for the same reason.
  """
  use Ash.Resource,
    domain: AshQuick.Test.VersioningDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :code, :string, public?: true, allow_nil?: false
    attribute :name, :string, public?: true
    attribute :note, :string, public?: true
  end

  identities do
    identity :unique_code, [:code], pre_check_with: AshQuick.Test.VersioningDomain
  end

  actions do
    defaults [:read]

    update :rename do
      accept [:name, :note]
      require_atomic? false
    end

    # On a conflict the row is written over with `name` and `note`.
    create :upsert do
      primary? true
      accept [:code, :name, :note]
      upsert? true
      upsert_identity :unique_code
      upsert_fields [:name, :note]
    end

    # Ash's widest `upsert_fields`: every attribute the create sets, the
    # counter's default included.
    create :upsert_all do
      accept [:code, :name, :note]
      upsert? true
      upsert_identity :unique_code
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

    audit do
      enabled? false
    end

    bookkeeping do
      inserted_at false
      inserted_by false
      updated_by false
    end
  end
end
