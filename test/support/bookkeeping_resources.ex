defmodule AshQuick.Test.Bookkeeping.Domain do
  @moduledoc """
  Holds the shapes the derived ignore list is read off, which are never written
  — the derivation only introspects — and `AshQuick.Test.Bookkeeping.Stamped`,
  which is.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshQuick.Test.Bookkeeping.AllFour do
  @moduledoc """
  A resource carrying every bookkeeping field there is.

  The widest the derived list gets, and the shape most of a host's resources
  are in: the actor has to appear twice over, as its column in the attribute
  half and as its relationship in the other.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Bookkeeping.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  actions do
    default_accept [:name]
    defaults [:read, :create]
  end

  ash_quick do
    display do
      label :name
    end

    liveness do
      enabled? false
    end

    versioning do
      enabled? false
    end
  end
end

defmodule AshQuick.Test.Bookkeeping.CreateOnly do
  @moduledoc """
  A resource that is written once and never updated, so it carries only the
  create half: `inserted_at` and an actor column, and nothing about updating.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Bookkeeping.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  actions do
    default_accept [:name]
    defaults [:read, :create]
  end

  ash_quick do
    display do
      label :name
    end

    liveness do
      enabled? false
    end

    versioning do
      enabled? false
    end

    bookkeeping do
      updated_at false
      updated_by false
    end
  end
end

defmodule AshQuick.Test.Bookkeeping.TimestampsOnly do
  @moduledoc """
  A resource nobody is the author of: both timestamps, neither actor.

  The shape a trail of system-written rows is in — there is a time it happened
  and no user to attribute it to.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Bookkeeping.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  actions do
    default_accept [:name]
    defaults [:read, :create]
  end

  ash_quick do
    display do
      label :name
    end

    liveness do
      enabled? false
    end

    versioning do
      enabled? false
    end

    bookkeeping do
      inserted_by false
      updated_by false
    end
  end
end

defmodule AshQuick.Test.Bookkeeping.HandWrittenActorColumn do
  @moduledoc """
  A resource whose actor relationship carries a column the host wrote itself.

  `belongs_to :updated_by` with `define_attribute? false` over a hand-written
  `:updated_by_id`, which is what a host does when the column needs an option
  the generated one would not carry — `always_select?: true` here. Guessing the
  column as `:"\#{name}_id"` lands on the same atom by luck; reading
  `source_attribute` off the relationship is what makes it correct, and only a
  resource shaped like this can tell the two apart.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Bookkeeping.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :updated_by_id, :uuid, always_select?: true
  end

  relationships do
    belongs_to :updated_by, AshQuick.Test.Actor do
      domain AshQuick.Test.Accounts
      define_attribute? false
    end
  end

  actions do
    default_accept [:name]
    defaults [:read, :create]
  end

  ash_quick do
    display do
      label :name
    end

    liveness do
      enabled? false
    end

    versioning do
      enabled? false
    end
  end
end

defmodule AshQuick.Test.Bookkeeping.Stamped do
  @moduledoc """
  A resource whose updates show when `updated_by` is stamped: only on a write
  that changes something besides bookkeeping.

  It carries all four bookkeeping fields, is versioned and is audited, so one
  write shows the stamp, the timestamp, the lock and the audit row together.
  `:rename` and `:download` keep Ash's `require_atomic? true`; the
  `_in_memory` twins are the same writes on the in-memory path. `:download`
  records that something happened and writes nothing. `:exclaim_in_memory`
  writes through an expression on the in-memory path.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Bookkeeping.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  require Ash.Expr

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  actions do
    defaults [:read, create: [:name]]

    update :rename, accept: [:name]

    update :rename_in_memory do
      accept [:name]
      require_atomic? false
      change fn changeset, _context -> changeset end
    end

    update :download, accept: []

    # An in-memory write whose value is an expression: `atomic_update/3` files
    # it under `changeset.atomics` on this path too.
    update :exclaim_in_memory do
      accept []
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.atomic_update(changeset, :name, Ash.Expr.expr(name <> "!"))
      end
    end

    update :download_in_memory do
      accept []
      require_atomic? false
      change fn changeset, _context -> changeset end
    end
  end

  ash_quick do
    display do
      label :name
    end

    liveness do
      enabled? false
    end
  end
end
