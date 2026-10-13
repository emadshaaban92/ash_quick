defmodule Example.Test.RequiredEntries.Domain do
  @moduledoc "Holds the resource whose create refuses to save without a nested entry."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.RequiredEntries.Entry do
  @moduledoc "One nested entry: a sub-form of its own on the parent's form."
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :label, :string, allow_nil?: true, public?: true
  end
end

defmodule Example.Test.RequiredEntries do
  @moduledoc """
  A create that needs at least one nested entry, and a page over it.

  The entries are an array of embeds, so the form renders them as sub-forms
  under an "Add" link rather than as an input. A save with none added posts
  nothing under the field, and the error the action refuses it with has to
  show in the field's section all the same.

  In ETS rather than Postgres, like `Example.Test.DigitsOnly`.
  """
  require Ash.Query

  use Ash.Resource,
    domain: Example.Test.RequiredEntries.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:code, :entries]

      validate fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :entries) do
          empty when empty in [nil, []] -> {:error, field: :entries, message: "add at least one"}
          _entries -> :ok
        end
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

    attribute :entries, {:array, Example.Test.RequiredEntries.Entry},
      allow_nil?: true,
      default: [],
      public?: true
  end
end

defmodule Example.Test.RequiredEntriesLive.Quick do
  @moduledoc """
  The page over `Example.Test.RequiredEntries`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.RequiredEntries,
    list: [fields: [:code]],
    details: [fields: [:code]]
end
