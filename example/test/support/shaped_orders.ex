defmodule Example.Test.ShapedOrders.Domain do
  @moduledoc "Holds the resource whose form follows what is typed into it."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.ShapedOrders.NeverWritable do
  @moduledoc "A read-only field check no actor passes."
  @behaviour AshQuick.ReadOnlyFields.Check

  @impl true
  def match?(_context, _opts), do: false
end

defmodule Example.Test.ShapedOrders.Line do
  @moduledoc "One line of a bundle or a gift: a sub-form of its own on the order's form."
  use Ash.Resource, data_layer: :embedded

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    attribute :name, :string, public?: true
  end
end

defmodule Example.Test.ShapedOrders do
  @moduledoc """
  An order whose form changes with its kind, and the page over it, routed
  only in the test build. `Example.Test.ShapedOrdersLive.Quick`'s
  `adjust_form/2` says how:

    * `:discount_reason` shows only for a discount, which requires it;
    * `:gift_note` shows only for a gift;
    * `:code` is set once: an update shows it read-only;
    * `:lines`, sub-forms over an embedded array, show for a bundle and,
      read-only, for a gift;
    * `:price`, drawn by AshQuick's money input, is relabelled, given a
      placeholder, and required for the order coded `priced_code/0`.

  `:locked_code` is read-only for every actor, so the form never draws it,
  whatever the hook does.

  In ETS rather than Postgres: nothing here is about what lands in a table.
  The table is shared by every test, so each one finds its rows by the codes
  it made.
  """
  use Ash.Resource,
    domain: Example.Test.ShapedOrders.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:code, :kind, :discount_reason, :gift_note, :locked_code, :lines, :price]
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:code, :kind, :discount_reason, :gift_note, :locked_code, :lines, :price]
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

    read_only_fields do
      read_only :locked_code,
        writable_if: Example.Test.ShapedOrders.NeverWritable,
        on: [:create, :update]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true

    attribute :kind, :atom,
      allow_nil?: false,
      default: :standard,
      public?: true,
      constraints: [one_of: [:standard, :discount, :gift, :bundle]]

    attribute :discount_reason, :string, public?: true
    attribute :gift_note, :string, public?: true
    attribute :locked_code, :string, public?: true

    attribute :lines, {:array, Example.Test.ShapedOrders.Line},
      public?: true,
      default: []

    attribute :price, :money, public?: true
  end
end

defmodule Example.Test.ShapedOrdersLive.Quick do
  @moduledoc """
  The page over `Example.Test.ShapedOrders`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.

  Its `adjust_form/2` also reaches past `AshQuick.FormState`'s functions, the
  way a careless hook could: it puts `:locked_code`, which Ash leaves out of
  the form, into the state, and makes `:code`, which Ash requires, optional.
  AshQuick takes neither.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.ShapedOrders,
    list: [fields: [:code, :kind, :discount_reason, :gift_note]],
    details: [fields: [:code, :kind, :discount_reason, :gift_note]]

  alias AshQuick.FormState

  @doc "What the hook puts under the gift note."
  def gift_help, do: "Printed on the card"

  @doc "The code of the one order whose price is required."
  def priced_code, do: "PRICED"

  defp adjust_form(%{action: %{name: action}} = state, _options)
       when action in [:create, :update] do
    kind = FormState.value(state, :kind)

    state
    |> FormState.hide(:discount_reason, kind != :discount)
    |> FormState.require(:discount_reason, kind == :discount)
    |> FormState.hide(:gift_note, kind != :gift)
    |> FormState.put_help(:gift_note, gift_help())
    |> FormState.put_attrs(:code, placeholder: "ORD-1")
    |> FormState.disable(:code, action == :update)
    |> FormState.hide(:lines, kind not in [:bundle, :gift])
    |> FormState.disable(:lines, kind == :gift)
    |> FormState.put_label(:price, "Total")
    |> FormState.put_attrs(:price, placeholder: "0.00")
    |> FormState.require(:price, FormState.value(state, :code) == priced_code())
    |> overreach()
  end

  defp adjust_form(state, _options), do: state

  defp overreach(state) do
    locked = %FormState.Field{
      name: :locked_code,
      inputs: [:locked_code],
      kind: :text,
      label: "Locked code",
      source: Ash.Resource.Info.attribute(Example.Test.ShapedOrders, :locked_code)
    }

    fields =
      Enum.map(state.fields, fn
        %{name: :code} = field -> %{field | required?: false}
        field -> field
      end)

    %{state | fields: fields ++ [locked]}
  end
end
