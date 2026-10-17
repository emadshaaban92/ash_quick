defmodule Example.Test.HiddenAddress.Domain do
  @moduledoc "Holds the resource whose sub-form sits under a field nobody sees."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.HiddenAddress.Address do
  @moduledoc "A single embed that refuses to be saved without a street."
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :street, :string, allow_nil?: false, public?: true
  end
end

defmodule Example.Test.HiddenAddress.NeverVisible do
  @moduledoc "A field-restriction check no actor passes."
  @behaviour AshQuick.FieldRestrictions.Check

  @impl true
  def match?(_context, _opts), do: false
end

defmodule Example.Test.HiddenAddress do
  @moduledoc """
  A create whose `address` embed is restricted away from every actor, and a
  page over it.

  The form still builds the embed's sub-form, and the sub-form refuses the save
  for want of a street, but the page draws none of it: the refusal has to be
  flashed, since there is no input to show it under.

  In ETS rather than Postgres, like `Example.Test.DigitsOnly`.
  """
  require Ash.Query

  use Ash.Resource,
    domain: Example.Test.HiddenAddress.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:code, :address]
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

    field_restrictions do
      restrict :address, Example.Test.HiddenAddress.NeverVisible, on: [:create]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true
    attribute :address, Example.Test.HiddenAddress.Address, allow_nil?: true, public?: true
  end
end

defmodule Example.Test.HiddenAddressLive.Quick do
  @moduledoc """
  The page over `Example.Test.HiddenAddress`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.HiddenAddress,
    list: [fields: [:code]],
    details: [fields: [:code]]
end
