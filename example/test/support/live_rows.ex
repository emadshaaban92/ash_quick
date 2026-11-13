defmodule Example.Test.LiveRows.Domain do
  @moduledoc "Holds the resource a live list reads only part of."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.LiveRows do
  @moduledoc """
  A live resource whose readers see only the rows not marked `hidden`, so a
  list over it can be told about a record its reader may not read.

  In ETS rather than Postgres: nothing here is about what lands in a table.
  """
  use Ash.Resource,
    domain: Example.Test.LiveRows.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  actions do
    defaults [:read, :destroy, create: [:name, :hidden], update: [:name, :hidden]]

    read :index do
      argument :search, :string
      prepare build(sort: [name: :asc])

      pagination do
        keyset? true
        offset? true
        default_limit 20
        countable :by_default
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(hidden == false)
    end

    policy always() do
      authorize_if always()
    end
  end

  ash_quick do
    display do
      label :name
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
    attribute :hidden, :boolean, allow_nil?: false, default: false, public?: true
  end
end

defmodule Example.Test.LiveRowsLive.Quick do
  @moduledoc """
  The page over `Example.Test.LiveRows`, routed only in the test build — see
  the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.LiveRows,
    list: [fields: [:name]],
    details: [fields: [:name]]
end
