defmodule Example.Test.KeyedItems.Item do
  @moduledoc """
  One item of `Example.Test.KeyedItems`: an embed with a public primary key,
  which its sub-form posts, so AshPhoenix matches a posted row to its own
  stored row wherever it is posted.
  """
  use Ash.Resource, data_layer: :embedded

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    uuid_primary_key :id, public?: true

    attribute :kind, :atom,
      allow_nil?: false,
      default: :good,
      public?: true,
      constraints: [one_of: [:good, :device]]

    attribute :serial, :string, public?: true
    attribute :discount, :integer, public?: true
  end
end

defmodule Example.Test.KeyedItems do
  @moduledoc """
  A bundle whose items are embeds with a primary key, under the rules
  `Example.Test.KeyedItemsLive.Quick` states. In ETS, like
  `Example.Test.ShapedBundles`, whose items have no key.
  """
  use Ash.Resource,
    domain: Example.Test.ManagedRows.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:code, :items]]

    update :update do
      primary? true
      require_atomic? false
      accept [:code, :items]
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
    attribute :items, {:array, Example.Test.KeyedItems.Item}, public?: true, default: []
  end
end

defmodule Example.Test.KeyedItemsLive.Quick do
  @moduledoc """
  The page over `Example.Test.KeyedItems`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`. An item's serial
  shows only for a device, and its discount is read-only.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.KeyedItems,
    list: [fields: [:code]],
    details: [fields: [:code]]

  alias AshQuick.FormState

  defp adjust_form(%{action: %{name: action}} = state, _options)
       when action in [:create, :update] do
    FormState.update_each(state, [:items], fn item ->
      item
      |> FormState.hide(:serial, FormState.value(item, :kind) != :device)
      |> FormState.disable(:discount)
    end)
  end

  defp adjust_form(state, _options), do: state
end
