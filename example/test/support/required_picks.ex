defmodule Example.Test.RequiredPicks.Domain do
  @moduledoc "Holds the resource whose create refuses to save without its picks."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.RequiredPicks do
  @moduledoc """
  A required relationship, a required atom and a required array of atoms, each
  rendered by a select widget rather than `input/1`, and a page over it. The
  update takes the two single selects, which can be cleared of a stored value.
  `:retag` and `:clear_tags` edit only the tags, with and without the rule
  that one must be picked.

  The relationship points at `Example.Test.RequiredAttachments`, the nearest
  test resource with a lookup action, so nothing here reaches a demo page.
  An array holding nothing is `[]`, which `allow_nil?` lets through, so
  `:tags` is checked by hand.
  """
  require Ash.Query

  use Ash.Resource,
    domain: Example.Test.RequiredPicks.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:code, :kind, :tags, :owner_id]
      validate &__MODULE__.require_tags/2
    end

    update :update do
      primary? true
      accept [:kind, :owner_id]
    end

    update :retag do
      accept [:tags]
      require_atomic? false
      validate &__MODULE__.require_tags/2
    end

    update :clear_tags do
      accept [:tags]
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

  @doc false
  def require_tags(changeset, _context) do
    case Ash.Changeset.get_attribute(changeset, :tags) do
      empty when empty in [nil, []] -> {:error, field: :tags, message: "pick at least one"}
      _tags -> :ok
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
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:small, :large]]

    attribute :tags, {:array, :atom},
      public?: true,
      default: [],
      constraints: [items: [one_of: [:red, :blue]]]
  end

  relationships do
    belongs_to :owner, Example.Test.RequiredAttachments do
      allow_nil? false
      public? true
    end
  end
end

defmodule Example.Test.RequiredPicksLive.Quick do
  @moduledoc """
  The page over `Example.Test.RequiredPicks`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.RequiredPicks,
    list: [fields: [:code]],
    details: [fields: [:code]]
end
