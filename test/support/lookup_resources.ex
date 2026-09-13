defmodule AshQuick.Test.Lookup.Domain do
  @moduledoc """
  Holds the lookup fixtures below, which are never read — `Options.new/3` only
  ever introspects them.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshQuick.Test.Lookup.Unlisted do
  @moduledoc false
  use Ash.Resource,
    domain: AshQuick.Test.Lookup.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  # A destination with no lookup action at all — the shape of every child
  # resource nothing lists, and perfectly legal until something selects it.
  actions do
    defaults [:read, :create]
  end

  ash_quick do
    # None of these is ever written, so none carries a bookkeeping field, and
    # none has a page to publish to.
    bookkeeping do
      created_at false
      updated_at false
      created_by false
      updated_by false
    end

    liveness do
      enabled? false
    end
  end
end

defmodule AshQuick.Test.Lookup.Searchable do
  @moduledoc false
  use Ash.Resource,
    domain: AshQuick.Test.Lookup.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  relationships do
    belongs_to :unlisted, AshQuick.Test.Lookup.Unlisted do
      domain AshQuick.Test.Lookup.Domain
      public? true
    end
  end

  actions do
    create :create do
      accept [:name, :unlisted_id]
    end

    read :index do
      argument :search, :string

      pagination do
        keyset? true
        offset? true
        default_limit 20
        countable :by_default
      end
    end
  end

  ash_quick do
    # None of these is ever written, so none carries a bookkeeping field, and
    # none has a page to publish to.
    bookkeeping do
      created_at false
      updated_at false
      created_by false
      updated_by false
    end

    liveness do
      enabled? false
    end
  end
end

defmodule AshQuick.Test.Lookup.OtherName do
  @moduledoc false
  use Ash.Resource,
    domain: AshQuick.Test.Lookup.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  actions do
    read :search_them do
      argument :query, :string

      pagination do
        keyset? true
        offset? true
        default_limit 20
        countable :by_default
      end
    end
  end

  ash_quick do
    # None of these is ever written, so none carries a bookkeeping field, and
    # none has a page to publish to.
    bookkeeping do
      created_at false
      updated_at false
      created_by false
      updated_by false
    end

    liveness do
      enabled? false
    end

    lookup do
      action :search_them
      search_argument :query
    end
  end
end

defmodule AshQuick.Test.Lookup.NoExtension do
  @moduledoc false
  # A plain Ash resource. Legal, common, and reachable as a dropdown
  # destination the moment someone points a `belongs_to` at it — at which
  # point nothing has declared which of its actions a search runs through,
  # because it carries no place to declare one.
  use Ash.Resource,
    domain: AshQuick.Test.Lookup.Domain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  actions do
    defaults [:read, :create]
  end
end

defmodule AshQuick.Test.Lookup.PointsAtNoExtension do
  @moduledoc false
  use Ash.Resource,
    domain: AshQuick.Test.Lookup.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  relationships do
    belongs_to :target, AshQuick.Test.Lookup.NoExtension do
      domain AshQuick.Test.Lookup.Domain
      public? true
    end
  end

  actions do
    create :create do
      accept [:name, :target_id]
    end

    read :index do
      argument :search, :string

      pagination do
        keyset? true
        offset? true
        default_limit 20
        countable :by_default
      end
    end
  end

  ash_quick do
    # None of these is ever written, so none carries a bookkeeping field, and
    # none has a page to publish to.
    bookkeeping do
      created_at false
      updated_at false
      created_by false
      updated_by false
    end

    liveness do
      enabled? false
    end
  end
end

defmodule AshQuick.Test.Lookup.PointsAtOtherName do
  @moduledoc false
  # A destination that satisfies the contract under a name of its own, so a
  # dropdown onto it resolves `:search_them` and a literal `:index` would not.
  use Ash.Resource,
    domain: AshQuick.Test.Lookup.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  relationships do
    belongs_to :target, AshQuick.Test.Lookup.OtherName do
      domain AshQuick.Test.Lookup.Domain
      public? true
    end
  end

  actions do
    create :create do
      accept [:name, :target_id]
    end

    read :index do
      argument :search, :string

      pagination do
        keyset? true
        offset? true
        default_limit 20
        countable :by_default
      end
    end
  end

  ash_quick do
    # None of these is ever written, so none carries a bookkeeping field, and
    # none has a page to publish to.
    bookkeeping do
      created_at false
      updated_at false
      created_by false
      updated_by false
    end

    liveness do
      enabled? false
    end
  end
end
