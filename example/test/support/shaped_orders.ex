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

defmodule Example.Test.ShapedOrders.Customer do
  @moduledoc "Who an order is for: picked through a `belongs_to` on the order's form."
  use Ash.Resource,
    domain: Example.Test.ShapedOrders.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:name]]

    read :index do
      argument :search, :string

      pagination do
        keyset? true
        offset? true
        default_limit 250
        countable :by_default
      end
    end
  end

  ash_quick do
    display do
      label :name
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
    attribute :name, :string, allow_nil?: false, public?: true
  end
end

defmodule Example.Test.ShapedOrders.Tag do
  @moduledoc "What an order is tagged with: picked through a many-to-many argument."
  use Ash.Resource,
    domain: Example.Test.ShapedOrders.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:name]]

    read :index do
      argument :search, :string

      pagination do
        keyset? true
        offset? true
        default_limit 250
        countable :by_default
      end
    end
  end

  ash_quick do
    display do
      label :name
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
    attribute :name, :string, allow_nil?: false, public?: true
  end
end

defmodule Example.Test.ShapedOrders.Tagging do
  @moduledoc "The join between an order and its tags."
  use Ash.Resource,
    domain: Example.Test.ShapedOrders.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy, create: [:order_id, :tag_id]]
  end

  relationships do
    belongs_to :order, Example.Test.ShapedOrders,
      primary_key?: true,
      allow_nil?: false,
      public?: true

    belongs_to :tag, Example.Test.ShapedOrders.Tag,
      primary_key?: true,
      allow_nil?: false,
      public?: true
  end
end

defmodule Example.Test.ShapedOrders do
  @moduledoc """
  An order whose form changes with its kind, and the page over it, routed
  only in the test build. `Example.Test.ShapedOrdersLive.Quick`'s
  `adjust_form/2` says how:

    * `:discount_reason` shows only for a discount, drawn required there,
      as the resource's validation requires it, and an update to another
      kind clears it;
    * `:gift_note` shows only for a gift;
    * `:code` is set once: an update shows it read-only;
    * `:lines`, sub-forms over an embedded array, show for a bundle and,
      read-only, for a gift;
    * `:price`, drawn by AshQuick's money input, is relabelled, given a
      placeholder, and required for the order coded `priced_code/0`;
    * `:customer` (a `belongs_to`, posting `customer_id`), `:tag_ids` (an
      argument over a many-to-many) and `:rush` (a plain argument) are
      hidden for a discount;
    * `:photo`, an attachment, shows only for a gift;
    * `:code` is hidden for a sample, on a create too, so Ash refuses a
      sample's create for the code it lacks, and its update refuses a
      sample's code and gift note, held back as they are: the errors have no
      input to show under.

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

      accept [
        :code,
        :kind,
        :discount_reason,
        :gift_note,
        :locked_code,
        :lines,
        :price,
        :customer_id,
        :photo
      ]

      argument :tag_ids, {:array, :uuid}
      argument :rush, :boolean
      change manage_relationship(:tag_ids, :tags, type: :append_and_remove)
      change set_attribute(:rushed, arg(:rush))

      # The rule the hook's `require/3` draws, as `AshQuick.FormState`
      # says: the hook only shapes the page.
      validate present(:discount_reason), where: [attribute_equals(:kind, :discount)]
    end

    update :update do
      primary? true
      require_atomic? false

      accept [
        :code,
        :kind,
        :discount_reason,
        :gift_note,
        :locked_code,
        :lines,
        :price,
        :customer_id,
        :photo
      ]

      argument :tag_ids, {:array, :uuid}
      argument :rush, :boolean
      change manage_relationship(:tag_ids, :tags, type: :append_and_remove)
      change set_attribute(:rushed, arg(:rush))

      # What `AshQuick.FormState` suggests for a value that must not outlive
      # the kind that shows it: hidden, an update would keep it.
      change set_attribute(:discount_reason, nil),
        where: [attribute_does_not_equal(:kind, :discount)]

      validate present(:discount_reason), where: [attribute_equals(:kind, :discount)]
      validate absent(:code), where: [attribute_equals(:kind, :sample)]
      validate absent(:gift_note), where: [attribute_equals(:kind, :sample)]
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
      constraints: [one_of: [:standard, :discount, :gift, :bundle, :sample]]

    attribute :discount_reason, :string, public?: true
    attribute :gift_note, :string, public?: true
    attribute :locked_code, :string, public?: true

    attribute :lines, {:array, Example.Test.ShapedOrders.Line},
      public?: true,
      default: []

    attribute :price, :money, public?: true
    attribute :rushed, :boolean, public?: true

    attribute :photo, :attachment,
      public?: true,
      constraints: [visibility: :private, accepts: [:image], max_size_mb: 10]
  end

  relationships do
    belongs_to :customer, Example.Test.ShapedOrders.Customer, public?: true

    many_to_many :tags, Example.Test.ShapedOrders.Tag do
      through Example.Test.ShapedOrders.Tagging
      source_attribute_on_join_resource :order_id
      destination_attribute_on_join_resource :tag_id
      public? true
    end
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

  The gift note is drawn by a widget, from its `@state_field`, and the update
  page by a template of its own that reads `@ash_quick_form_state` before it
  draws the generic form. The create page's template draws a file input for
  `:photo` while the state holds it back, the way a careless template could,
  so a test can upload to a field the state hides.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.ShapedOrders,
    list: [fields: [:code, :kind, :discount_reason, :gift_note]],
    details: [fields: [:code, :kind, :discount_reason, :gift_note]],
    form: [widgets: %{gift_note: &__MODULE__.gift_note_input/1}]

  alias AshQuick.FormState

  @doc "What the hook puts under the gift note."
  def gift_help, do: "Printed on the card"

  @doc "The gift note's widget: drawn from the label and help the state gives it."
  def gift_note_input(assigns) do
    ~H"""
    <div class="sm:col-span-2" data-widget="gift_note">
      <.input field={@phx_field} type="text" label={@state_field.label} help={@state_field.help} />
    </div>
    """
  end

  @doc "The update page: which fields the state holds back, over the generic form."
  def action_update_html(assigns) do
    ~H"""
    <p
      id="held-fields"
      data-hidden={held(@ash_quick_form_state, :hidden?)}
      data-disabled={held(@ash_quick_form_state, :disabled?)}
    />
    {AshQuick.LiveView.QuickView.do_render(assigns, assigns.params, assigns.ash_action)}
    """
  end

  @doc "The create page: a stray file input for the photo, over the generic form."
  def action_create_html(assigns) do
    ~H"""
    <form :if={held?(@ash_quick_form_state, :photo)} id="stray-photo" phx-change="validate">
      <.live_file_input upload={@uploads["form[photo]_upload"]} />
    </form>
    {AshQuick.LiveView.QuickView.do_render(assigns, assigns.params, assigns.ash_action)}
    """
  end

  defp held(%FormState{fields: fields}, flag),
    do: fields |> Enum.filter(&Map.fetch!(&1, flag)) |> Enum.map_join(" ", & &1.name)

  defp held(_none, _flag), do: ""

  defp held?(%FormState{} = state, name) do
    case FormState.field(state, name) do
      %{hidden?: hidden?, disabled?: disabled?} -> hidden? or disabled?
      nil -> false
    end
  end

  defp held?(_none, _name), do: false

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
    |> FormState.put_label(:gift_note, "Card note")
    |> FormState.put_attrs(:code, placeholder: "ORD-1")
    |> FormState.disable(:code, action == :update)
    |> FormState.hide(:code, kind == :sample)
    |> FormState.hide(:lines, kind not in [:bundle, :gift])
    |> FormState.disable(:lines, kind == :gift)
    |> FormState.put_label(:price, "Total")
    |> FormState.put_attrs(:price, placeholder: "0.00")
    |> FormState.require(:price, FormState.value(state, :code) == priced_code())
    |> FormState.hide(:customer, kind == :discount)
    |> FormState.hide(:tag_ids, kind == :discount)
    # `read_only_fields` keeps every actor from writing it, so it is in no
    # actor's state: naming it is a no-op, not an error.
    |> FormState.disable(:locked_code)
    |> FormState.hide(:rush, kind == :discount)
    |> FormState.hide(:photo, kind != :gift)
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
