defmodule Example.Test.SortedRows.Domain do
  @moduledoc "Holds the resources behind a list sorted by its columns."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.SortedRows.Owner do
  @moduledoc "Who an `Example.Test.SortedRows` belongs to, one hop from the list."
  use Ash.Resource,
    domain: Example.Test.SortedRows.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, create: [:name]]
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
  end
end

defmodule Example.Test.SortedRows.Shouted do
  @moduledoc "A calculation Ash computes in Elixir, which no data layer sorts by."
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:code]

  @impl true
  def calculate(records, _opts, _context), do: Enum.map(records, &String.upcase(&1.code))
end

defmodule Example.Test.SortedRows do
  @moduledoc """
  A resource whose list columns are every kind a sort meets — attributes, a
  list, an expression and an Elixir calculation, a relationship path and one
  through a relationship marked `sortable? false` — and two pages over it: one
  that leaves its sortable columns unsaid, one that names them and sets a
  `sort_by`.

  In ETS rather than Postgres: the order is Ash's to apply, whatever the data
  layer. The table is shared, so only `ExampleWeb.SortScenarioTest` writes to
  it.
  """
  use Ash.Resource,
    domain: Example.Test.SortedRows.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:code, :rank]]

    # Private, so the page's own create form offers no owner dropdown, which
    # would need the extension on `Owner` too.
    create :seed do
      public? false
      accept [:code, :rank, :tags, :owner_id]
    end

    read :index do
      argument :search, :string

      prepare build(sort: [code: :asc])

      pagination do
        keyset? true
        offset? true
        default_limit 2
        max_page_size 5
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
    attribute :rank, :integer, public?: true
    attribute :tags, {:array, :string}, public?: true, default: []
  end

  relationships do
    belongs_to :owner, Example.Test.SortedRows.Owner, public?: true
    belongs_to :keeper, Example.Test.SortedRows.Owner, public?: true, sortable?: false
  end

  calculations do
    calculate :negated, :integer, expr(-rank), public?: true
    calculate :shouted, :string, Example.Test.SortedRows.Shouted, public?: true
  end
end

defmodule Example.Test.SortedRowsLive.Quick do
  @moduledoc """
  The page over `Example.Test.SortedRows` that leaves `sortable` unsaid, routed
  only in the test build — see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.SortedRows,
    list: [
      fields: [:code, :rank, :tags, :negated, :shouted, [owner: :name], [keeper: :name]]
    ],
    details: [fields: [:code]]
end

defmodule Example.Test.SortedRowsNamedLive.Quick do
  @moduledoc """
  The page over `Example.Test.SortedRows` that names the one column it may be
  sorted by, a relationship path, and orders by rank, highest first, before
  the action's own sort by code.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.SortedRows,
    sort_by: [rank: :desc],
    list: [fields: [:code, :rank, [owner: :name]], sortable: [[owner: :name]]],
    details: [fields: [:code]]
end
