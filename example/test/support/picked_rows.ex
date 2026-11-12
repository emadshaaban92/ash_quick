defmodule Example.Test.PickedRows.Domain do
  @moduledoc "Holds the resource whose rows each pick from dropdowns of their own."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.PickedRows.Bin do
  @moduledoc "What a row, or the parent itself, is put in: picked from a dropdown."
  use Ash.Resource,
    domain: Example.Test.PickedRows.Domain,
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
end

defmodule Example.Test.PickedRows.Row do
  @moduledoc """
  One row of `Example.Test.PickedRows`: a sub-form with a value picked from a
  fixed set and a bin picked from a dropdown, both named as the parent's own.
  """
  use Ash.Resource,
    domain: Example.Test.PickedRows.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:kind, :bin_id]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :kind, :atom,
      constraints: [one_of: [:small, :large]],
      allow_nil?: true,
      public?: true
  end

  relationships do
    belongs_to :bin, Example.Test.PickedRows.Bin, public?: true
    belongs_to :picked_rows, Example.Test.PickedRows, public?: true
  end
end

defmodule Example.Test.PickedRows do
  @moduledoc """
  A create that brings its rows along through `manage_relationship`, and a page
  over it.

  The parent and each row pick a `kind` from a fixed set and a `bin` from a
  dropdown, so every row's dropdowns share their field names with the other
  rows' and with the parent's.

  In ETS rather than Postgres: nothing here is about what lands in a table.
  """
  use Ash.Resource,
    domain: Example.Test.PickedRows.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:code, :kind, :bin_id]
      argument :rows, {:array, :map}, allow_nil?: true, default: []
      change manage_relationship(:rows, type: :create)
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

    attribute :kind, :atom,
      constraints: [one_of: [:small, :large]],
      allow_nil?: true,
      public?: true
  end

  relationships do
    belongs_to :bin, Example.Test.PickedRows.Bin, public?: true
    has_many :rows, Example.Test.PickedRows.Row, public?: true
  end
end

defmodule Example.Test.PickedRowsLive.Quick do
  @moduledoc """
  The page over `Example.Test.PickedRows`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.PickedRows,
    list: [fields: [:code]],
    details: [fields: [:code]]
end
