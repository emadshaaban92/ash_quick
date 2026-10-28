defmodule Example.Test.ShelvedCrates.Domain do
  @moduledoc "Holds the crates whose shelf is picked from a dropdown hinting a tenant-scoped count."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.ShelvedCrates.Item do
  @moduledoc """
  An item on a shelf, held per tenant with no `global?`: counting a shelf's
  items needs a tenant, and a reader without one cannot ask.
  """
  use Ash.Resource,
    domain: Example.Test.ShelvedCrates.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, create: [:shelf_id]]
  end

  multitenancy do
    strategy :attribute
    attribute :store_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :store_id, :uuid, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :shelf, Example.Test.ShelvedCrates.Shelf, public?: true
  end
end

defmodule Example.Test.ShelvedCrates.Shelf do
  @moduledoc """
  What a crate is put on, hinted by how many items the reader's store keeps
  on it — an aggregate over `Example.Test.ShelvedCrates.Item`, so a reader
  without a tenant gets no hint rather than a failed read.
  """
  use Ash.Resource,
    domain: Example.Test.ShelvedCrates.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:name]]

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
    display do
      label :name
      hint :item_count
    end

    versioning do
      enabled? false
    end

    audit do
      enabled? false
    end

    bookkeeping do
      inserted_at false
      inserted_by false
      updated_at false
      updated_by false
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
  end

  relationships do
    has_many :items, Example.Test.ShelvedCrates.Item, public?: true
  end

  aggregates do
    count :item_count, :items, public?: true
  end
end

defmodule Example.Test.ShelvedCrates do
  @moduledoc """
  A crate put on a shelf through a dropdown, and a page over it.

  In ETS rather than Postgres: nothing here is about what lands in a table.
  """
  use Ash.Resource,
    domain: Example.Test.ShelvedCrates.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, :destroy, create: [:code, :shelf_id], update: [:code, :shelf_id]]

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
    display do
      label :code
    end

    versioning do
      enabled? false
    end

    audit do
      enabled? false
    end

    bookkeeping do
      inserted_at false
      inserted_by false
      updated_at false
      updated_by false
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :shelf, Example.Test.ShelvedCrates.Shelf, public?: true
  end
end

defmodule Example.Test.ShelvedCratesLive.Quick do
  @moduledoc """
  The page over `Example.Test.ShelvedCrates`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.ShelvedCrates,
    list: [fields: [:code]],
    details: [fields: [:code]]
end
