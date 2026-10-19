defmodule Example.Test.LookupItems.Domain do
  @moduledoc "Holds the resource whose items can be looked up instead of created."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.LookupItems.Item do
  @moduledoc "One item of `Example.Test.LookupItems`, which a save can relate."
  use Ash.Resource,
    domain: Example.Test.LookupItems.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy, create: [:status], update: [:status]]
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :status, :string, allow_nil?: true, public?: true
  end

  relationships do
    belongs_to :lookup_items, Example.Test.LookupItems, public?: true
  end
end

defmodule Example.Test.LookupItems do
  @moduledoc """
  A create whose items are looked up and related when they exist, and a page
  over it.

  `on_lookup` with nothing to create gives each item's sub-form only a read
  action, so AshPhoenix builds every item a post sends for that read. The page
  offers no such item, so only a hand-sent post holds one; a failed save
  holding one still has to say what is wrong (issue #81).

  In ETS rather than Postgres, like `Example.Test.DigitsOnly`.
  """
  require Ash.Query

  use Ash.Resource,
    domain: Example.Test.LookupItems.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:code]
      argument :items, {:array, :map}, allow_nil?: true, default: []
      change manage_relationship(:items, on_lookup: :relate)
    end

    read :index do
      argument :search, :string

      prepare fn query, _context ->
        case Ash.Query.get_argument(query, :search) do
          blank when blank in [nil, ""] -> query
          search -> Ash.Query.filter(query, contains(code, ^search))
        end
      end

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
    has_many :items, Example.Test.LookupItems.Item, public?: true
  end
end

defmodule Example.Test.LookupItemsLive.Quick do
  @moduledoc """
  The page over `Example.Test.LookupItems`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.LookupItems,
    list: [fields: [:code]],
    details: [fields: [:code]]
end
