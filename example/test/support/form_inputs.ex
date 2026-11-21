defmodule Example.Test.FormInputs.Domain do
  @moduledoc "Holds the resource whose fields get an input by their type."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.FormInputs.Phone do
  @moduledoc """
  A phone number, as a type of its own, drawn by
  `Example.Test.FormInputs.PhoneInput` through `config :ash_quick,
  form_inputs:` in `config/test.exs`.
  """
  use Ash.Type.NewType, subtype_of: :string
end

defmodule Example.Test.FormInputs.Price do
  @moduledoc "A `Money` NewType the config does not name: it gets the money input."
  use Ash.Type.NewType,
    subtype_of: AshMoney.Types.Money,
    constraints: [ex_money_opts: [default_currency: :EUR, only: [:USD, :EUR]]]
end

defmodule Example.Test.FormInputs.PlainPrice do
  @moduledoc "A `Money` NewType the config maps to `false`: it gets the plain text input."
  use Ash.Type.NewType, subtype_of: AshMoney.Types.Money
end

defmodule Example.Test.FormInputs.PhoneInput do
  @moduledoc "A host's input for a phone number: a `tel` input."
  @behaviour AshQuick.FormInput
  use Phoenix.Component
  import AshQuick.Components, only: [input: 1]

  @impl AshQuick.FormInput
  def render(assigns) do
    ~H"""
    <.input
      field={@phx_field}
      type="tel"
      label={AshQuick.Labels.name(@field.name, @resource)}
      help={@help}
      data-phone-input
    />
    """
  end
end

defmodule Example.Test.FormInputs.PhonesInput do
  @moduledoc "A host's input for a list of phone numbers: one `tel` input per number."
  @behaviour AshQuick.FormInput
  use Phoenix.Component

  @impl AshQuick.FormInput
  def render(assigns) do
    assigns = assign(assigns, :numbers, List.wrap(assigns.phx_field.value) ++ [""])

    ~H"""
    <div class="sm:col-span-2" data-phones-input>
      <input :for={number <- @numbers} type="tel" name={@phx_field.name <> "[]"} value={number} />
    </div>
    """
  end
end

defmodule Example.Test.FormInputs.Box do
  @moduledoc "An embedded value holding a phone and a `Money`, drawn as a sub-form."
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :phone, Example.Test.FormInputs.Phone, public?: true

    attribute :deposit, :money,
      public?: true,
      constraints: [ex_money_opts: [default_currency: :USD, only: [:USD, :EUR]]]
  end
end

defmodule Example.Test.FormInputs do
  @moduledoc """
  A field for each way a form picks an input by the field's type: `Money`
  with any currency, with one, through a NewType and through one the config
  turns off; a type of the host's, as a scalar, a list, in an embed, under a
  page's widget and marked `sensitive?`.

  In ETS rather than Postgres, like `Example.Test.TypedInputs`.
  """
  use Ash.Resource,
    domain: Example.Test.FormInputs.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  @inputs [
    :code,
    :price,
    :fee,
    :tip,
    :plain,
    :phone,
    :alt_phone,
    :secret_phone,
    :phones,
    :box
  ]

  actions do
    defaults [:read, create: @inputs, update: @inputs]

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
    attribute :price, :money, public?: true

    attribute :fee, :money,
      allow_nil?: false,
      public?: true,
      constraints: [ex_money_opts: [only: [:EGP]]]

    attribute :tip, Example.Test.FormInputs.Price, public?: true
    attribute :plain, Example.Test.FormInputs.PlainPrice, public?: true
    attribute :phone, Example.Test.FormInputs.Phone, public?: true
    attribute :alt_phone, Example.Test.FormInputs.Phone, public?: true
    attribute :secret_phone, Example.Test.FormInputs.Phone, public?: true, sensitive?: true
    attribute :phones, {:array, Example.Test.FormInputs.Phone}, public?: true, default: []
    attribute :box, Example.Test.FormInputs.Box, public?: true
  end
end

defmodule Example.Test.FormInputsLive.Quick do
  @moduledoc """
  The page over `Example.Test.FormInputs`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`. Its widget for
  `:alt_phone` wins over the input the config names for the type.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.FormInputs,
    list: [fields: [:code, :price, :fee]],
    details: [fields: [:code, :price, :fee, :tip, :phone]],
    form: [widgets: %{alt_phone: &__MODULE__.alt_phone_input/1}]

  def alt_phone_input(assigns) do
    ~H"""
    <input type="text" name={@phx_field.name} value={@phx_field.value} data-widget />
    """
  end
end
