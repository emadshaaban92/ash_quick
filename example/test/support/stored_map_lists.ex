defmodule Example.Test.StoredMapLists.Domain do
  @moduledoc "Holds the resource whose field holds a list of stored maps."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.StoredMapLists do
  @moduledoc """
  A resource whose `:entries` is a list of maps of unknown shape,
  `{:array, :map}`, and a page over it: no table in this application holds
  one, so nothing else shows how a details page draws such a list or how an
  export writes it. No action takes `:entries`, which no form writes;
  `ExampleWeb.StoredMapScenarioTest` seeds its rows.

  In ETS rather than Postgres, like `Example.Test.OffsetPages`. The table is
  shared, so only `ExampleWeb.StoredMapScenarioTest` writes to it.
  """
  use Ash.Resource,
    domain: Example.Test.StoredMapLists.Domain,
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
    attribute :entries, {:array, :map}, public?: true
  end
end

defmodule Example.Test.StoredMapListsLive.Quick do
  @moduledoc """
  The page over `Example.Test.StoredMapLists`, routed only in the test build
  — see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.StoredMapLists,
    list: [fields: [:code, :entries]],
    details: [fields: [:code, :entries]]
end
