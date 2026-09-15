defmodule Example.Test.ColumnOnlyBrand.Domain do
  @moduledoc "Holds the resource whose `:active` is only a column."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.ColumnOnlyBrand do
  @moduledoc """
  `Example.Catalog.Brand`'s table, read by a resource that never declared
  activation.

  Other extensions put an `:active` column on resources for their own purposes.
  AshQuick reads the *declaration* rather than the column, and the difference is
  only visible where the two disagree — which nothing in this application does,
  because every resource here that has the column declared it.

  So the disagreement is built. Same table, same column, same rows; the one
  thing that differs is the `activation` block, which this resource does not
  have. A dropdown onto it must therefore keep its deactivated records, and
  `ExampleWeb.ActivationScenarioTest` pairs that against the declaring resource
  to show the filtering is real.
  """
  require Ash.Query

  use Ash.Resource,
    domain: Example.Test.ColumnOnlyBrand.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshQuick]

  postgres do
    table "brands"
    repo Example.Repo
  end

  actions do
    # Read-only: the rows come from `Example.Catalog.Brand`, which is what
    # makes this the same row seen through a different declaration rather than
    # a lookalike written beside it.
    defaults [:read]

    read :index do
      argument :search, :string

      prepare fn query, _context ->
        case Ash.Query.get_argument(query, :search) do
          blank when blank in [nil, ""] -> query
          search -> Ash.Query.filter(query, contains(name, ^search))
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
      label :name
    end

    # Nothing writes this resource through the UI, and the audit trail of the
    # rows it shares belongs to `Example.Catalog.Brand`.
    audit do
      enabled? false
    end

    bookkeeping do
      created_by false
      updated_by false
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :code, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true

    # Written out rather than declared, which is the whole point: the column is
    # here and the `activation` block is not.
    attribute :active, :boolean, allow_nil?: false, public?: true, default: true
  end
end
