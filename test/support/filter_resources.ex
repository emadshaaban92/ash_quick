defmodule AshQuick.Test.Filter.Domain do
  @moduledoc """
  Holds `AshQuick.Test.Filter.Ledger` and `AshQuick.Test.Filter.Posting`, the
  fixtures for which fields the filter form offers.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshQuick.Test.Filter.Shouted do
  @moduledoc """
  A calculation computed in Elixir only, with `calculate/3` and no
  `expression/2`: a data layer that filters in SQL has nothing to ask.
  """
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:name]

  @impl true
  def calculate(records, _opts, _context),
    do: Enum.map(records, &(&1.name && String.upcase(&1.name)))
end

defmodule AshQuick.Test.Filter.Ledger do
  @moduledoc """
  A resource with fields Ash lets a filter name only in part, beside ones it
  lets a filter name freely.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Filter.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    # Ash takes it only in a filter's one top-level `==`.
    attribute :reference, :string, public?: true, filterable?: :simple_equality
    attribute :note, :string, public?: true, filterable?: false
    # Shown masked, so a filter on it would give it back.
    attribute :pin, :string, public?: true, sensitive?: true
    # A map is asked at a key path in SQL, which only AshPostgres has.
    attribute :extra, :map, public?: true
  end

  actions do
    defaults [:read, create: [:name, :reference, :note, :pin]]
  end

  calculations do
    calculate :shouted, :string, AshQuick.Test.Filter.Shouted, public?: true
    calculate :whispered, :string, expr(string_downcase(name)), public?: true
  end
end

defmodule AshQuick.Test.Filter.Posting do
  @moduledoc """
  A row of an `AshQuick.Test.Filter.Ledger`, so the ledger's fields are one
  hop away through a belongs_to.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Filter.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :memo, :string, public?: true
  end

  relationships do
    belongs_to :ledger, AshQuick.Test.Filter.Ledger, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshQuick.Test.Filter.Preset do
  @moduledoc """
  A resource with a field named `defaults`, which `filterable:` reads as the
  marker for the fields the filter offers unsaid.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Filter.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :defaults, :string, public?: true
  end

  actions do
    defaults [:read]
  end
end
