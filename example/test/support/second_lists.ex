defmodule Example.Test.SecondLists.Domain do
  @moduledoc "Holds the resource listed through two actions."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.SecondLists do
  @moduledoc """
  A resource listed through two actions, and a page over it.

  `?action=` reaches a list other than the page's default, and every control on
  that list has to keep it there. Two rows a page, so five rows page.

  In ETS rather than Postgres, like `Example.Test.DefaultPages`. The table is
  shared, so only `ExampleWeb.SecondListScenarioTest` writes to it.
  """
  use Ash.Resource,
    domain: Example.Test.SecondLists.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:code]]

    read :index do
      argument :search, :string

      prepare build(sort: [code: :asc])

      pagination do
        keyset? true
        offset? true
        default_limit 2
        countable :by_default
      end
    end

    read :newest_first do
      argument :search, :string

      prepare build(sort: [code: :desc])

      pagination do
        keyset? true
        offset? true
        default_limit 2
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
end

defmodule Example.Test.SecondListsLive.Quick do
  @moduledoc """
  The page over `Example.Test.SecondLists`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.SecondLists,
    list: [fields: [:code]],
    details: [fields: [:code]]
end
