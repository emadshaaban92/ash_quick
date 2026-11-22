defmodule Example.Test.ValueLists.Domain do
  @moduledoc "Holds the resource whose fields are lists of plain values."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.ValueLists.Part do
  @moduledoc """
  A record a list holds many of, named by its label.
  """
  use Ash.Resource,
    domain: Example.Test.ValueLists.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:name, :value_list_id]]

    read :index do
      argument :search, :string

      pagination do
        keyset? true
        offset? true
        default_limit 250
        countable :by_default
      end
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
  end

  relationships do
    belongs_to :value_list, Example.Test.ValueLists, public?: true
  end
end

defmodule Example.Test.ValueLists do
  @moduledoc """
  Lists of plain values, and a page over them: words, whole numbers that may
  be negative, decimals and amounts, and the related records it has many of.
  Each shows its items as badges.
  """
  use Ash.Resource,
    domain: Example.Test.ValueLists.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:code]]

    read :index do
      argument :search, :string

      pagination do
        keyset? true
        offset? true
        default_limit 250
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
    attribute :words, {:array, :string}, public?: true, default: []
    attribute :readings, {:array, :integer}, public?: true, default: []
    attribute :weights, {:array, :decimal}, public?: true, default: []
    attribute :fees, {:array, AshMoney.Types.Money}, public?: true, default: []
  end

  relationships do
    has_many :parts, Example.Test.ValueLists.Part,
      public?: true,
      destination_attribute: :value_list_id
  end
end

defmodule Example.Test.ValueListsLive.Quick do
  @moduledoc """
  The page over `Example.Test.ValueLists`, routed only in the test build — see
  the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.ValueLists,
    list: [fields: [:code, :words, :readings, :weights, :fees, {[parts: :name], label: "Parts"}]],
    details: [
      fields: [:code, :words, :readings, :weights, :fees, {[parts: :name], label: "Parts"}]
    ]
end
