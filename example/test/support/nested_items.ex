defmodule Example.Test.NestedItems.Domain do
  @moduledoc "Holds the resource whose items refuse a value on their own form."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.NestedItems.Part do
  @moduledoc """
  A part of an item: a sub-form two levels down, under an item's sub-form.

  `"bad"` is refused against `name`, its input. `"secret"` is refused against
  `code`, which its form offers no input for. An embed is cast through a bulk
  create, which reads a validation's keyword error as an unknown one, so these
  are exceptions.
  """
  use Ash.Resource, data_layer: :embedded

  alias Ash.Error.Changes.InvalidAttribute

  actions do
    defaults [:read, :destroy, update: [:name]]

    create :create do
      primary? true
      accept [:name]

      validate fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :name) do
          "bad" -> {:error, InvalidAttribute.exception(field: :name, message: "is bad")}
          "secret" -> {:error, InvalidAttribute.exception(field: :code, message: "is secret")}
          _name -> :ok
        end
      end
    end
  end

  attributes do
    attribute :name, :string, allow_nil?: true, public?: true
    attribute :code, :string, allow_nil?: true, public?: true
  end
end

defmodule Example.Test.NestedItems.Address do
  @moduledoc "An optional single embed: a sub-form the page can remove."
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :street, :string, allow_nil?: true, public?: true
  end
end

defmodule Example.Test.NestedItems.Item do
  @moduledoc """
  One item of `Example.Test.NestedItems`: a sub-form of its own on the parent's
  form, whose create refuses some statuses.

  `"blocked"` is refused against `status`, the item's input. `"hidden"` is
  refused against `note`, which the item's form offers no input for. `"late"`
  is refused against `status` only when the create runs, `"late_hidden"`
  against `note` only then. `"broken"` fails with
  an error that is about no input and is not a policy's.
  """
  use Ash.Resource,
    domain: Example.Test.NestedItems.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:status, :parts]

      validate fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :status) do
          "blocked" -> {:error, field: :status, message: "is blocked"}
          "hidden" -> {:error, field: :note, message: "is hidden"}
          "broken" -> {:error, Ash.Error.Unknown.UnknownError.exception(error: "broken")}
          _status -> :ok
        end
      end

      # Only once the action runs, so the sub-form validates clean and the
      # refusal comes back from the parent's submit at the item's path.
      validate fn changeset, _context ->
                 case Ash.Changeset.get_attribute(changeset, :status) do
                   "late" -> {:error, field: :status, message: "is refused on save"}
                   "late_hidden" -> {:error, field: :note, message: "is hidden on save"}
                   _status -> :ok
                 end
               end,
               before_action?: true
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :status, :string, allow_nil?: true, public?: true
    attribute :note, :string, allow_nil?: true, public?: true
    attribute :parts, {:array, Example.Test.NestedItems.Part}, allow_nil?: true, public?: true
  end

  relationships do
    belongs_to :nested_items, Example.Test.NestedItems, public?: true
  end
end

defmodule Example.Test.NestedItems do
  @moduledoc """
  A create that brings its items along through `manage_relationship`, and a
  page over it.

  Each item is a sub-form of the parent's form, built for the item's own create.
  An error that create refuses an item with is filed at the item's path
  (`[:items, 0]`), so the parent form itself has nothing to say about any input:
  the save failed for a reason only the sub-form shows. Each item's `parts` are
  sub-forms two levels down, and `address` is a single sub-form the page can
  remove.

  In ETS rather than Postgres, like `Example.Test.DigitsOnly`.
  """
  require Ash.Query

  use Ash.Resource,
    domain: Example.Test.NestedItems.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:code, :address]
      argument :items, {:array, :map}, allow_nil?: true, default: []
      change manage_relationship(:items, type: :create)
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
    attribute :address, Example.Test.NestedItems.Address, allow_nil?: true, public?: true
  end

  relationships do
    has_many :items, Example.Test.NestedItems.Item, public?: true
  end
end

defmodule Example.Test.NestedItemsLive.Quick do
  @moduledoc """
  The page over `Example.Test.NestedItems`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.NestedItems,
    list: [fields: [:code]],
    details: [fields: [:code]]
end
