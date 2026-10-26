defmodule Example.Test.ShadowedArguments.Domain do
  @moduledoc "Holds the resource whose attachment arguments share a field's name."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.ShadowedArguments do
  @moduledoc """
  An update whose attachment arguments are named after fields of the record
  that are not attachments: `:documents` after a calculation the form never
  loads, and `:cover` after a plain string attribute.

  A save with nothing picked must leave each argument to its own default, not
  fill it with what the record holds under the same name (issue #103). The
  action counts what it was given into `:shipped_with`, so a test can read
  what arrived.

  In ETS rather than Postgres, like `Example.Test.RequiredAttachments`: nothing
  here is about what lands in a table.
  """
  require Ash.Query

  use Ash.Resource,
    domain: Example.Test.ShadowedArguments.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:code, :cover]]

    update :ship do
      accept []
      require_atomic? false

      argument :documents, {:array, :attachment} do
        default []
        constraints items: [visibility: :private, accepts: [:document]]
      end

      argument :cover, :attachment do
        constraints visibility: :private, accepts: [:image]
      end

      change fn changeset, _context ->
        documents = Ash.Changeset.get_argument(changeset, :documents) || []
        cover = Ash.Changeset.get_argument(changeset, :cover)
        shipped_with = length(documents) + if(cover, do: 1, else: 0)

        Ash.Changeset.force_change_attribute(changeset, :shipped_with, shipped_with)
      end
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
    attribute :cover, :string, public?: true
    attribute :shipped_with, :integer, public?: true
  end

  calculations do
    calculate :documents, {:array, :string}, Example.Test.ShadowedArguments.Documents,
      public?: true
  end
end

defmodule Example.Test.ShadowedArguments.Documents do
  @moduledoc "A module calculation, so nothing loads it unless asked."
  use Ash.Resource.Calculation

  @impl true
  def calculate(records, _opts, _context),
    do: Enum.map(records, fn _record -> ["packing.pdf"] end)
end

defmodule Example.Test.ShadowedArgumentsLive.Quick do
  @moduledoc """
  The page over `Example.Test.ShadowedArguments`, routed only in the test
  build — see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.ShadowedArguments,
    list: [fields: [:code]],
    details: [fields: [:code, :shipped_with]]
end
