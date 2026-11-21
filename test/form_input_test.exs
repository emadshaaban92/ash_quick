defmodule AshQuick.FormInputTest.Phone do
  @moduledoc "A phone number, as a type of its own."
  use Ash.Type.NewType, subtype_of: :string
end

defmodule AshQuick.FormInputTest.MobilePhone do
  @moduledoc "A phone number of a narrower kind, two NewTypes deep."
  use Ash.Type.NewType, subtype_of: AshQuick.FormInputTest.Phone
end

defmodule AshQuick.FormInputTest.PhoneInput do
  @moduledoc "A host's input for a phone number."
  @behaviour AshQuick.FormInput
  use Phoenix.Component

  @impl true
  def render(assigns) do
    ~H"""
    <input type="tel" name={@phx_field.name} />
    """
  end
end

defmodule AshQuick.FormInputTest.MobileInput do
  @moduledoc "A host's input for a mobile number."
  @behaviour AshQuick.FormInput
  use Phoenix.Component

  @impl true
  def render(assigns) do
    ~H"""
    <input type="tel" data-mobile />
    """
  end
end

defmodule AshQuick.FormInputTest do
  @moduledoc """
  `config :ash_quick, form_inputs:` names the input a form draws for every
  field of a type: the field's own type first, then each NewType under it, a
  list only by a list key, and `false` turning a type's input off.
  """
  use ExUnit.Case, async: false

  alias Ash.Resource.Actions.Argument
  alias Ash.Resource.Attribute
  alias AshQuick.FormInput
  alias AshQuick.FormInputTest.{MobileInput, MobilePhone, Phone, PhoneInput}

  setup do
    previous = Application.fetch_env(:ash_quick, :form_inputs)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash_quick, :form_inputs, value)
        :error -> Application.delete_env(:ash_quick, :form_inputs)
      end
    end)
  end

  defp configure(inputs), do: Application.put_env(:ash_quick, :form_inputs, inputs)

  defp attribute(type), do: %Attribute{name: :phone, type: type}

  test "no config draws no input of the host's" do
    Application.delete_env(:ash_quick, :form_inputs)

    assert FormInput.module(attribute(Phone)) == nil
    assert FormInput.module(attribute(Ash.Type.String)) == nil
  end

  test "a type's input draws its fields, and those of each NewType of it" do
    configure(%{Phone => PhoneInput})

    assert FormInput.module(attribute(Phone)) == PhoneInput
    assert FormInput.module(attribute(MobilePhone)) == PhoneInput
    assert FormInput.module(%Argument{name: :phone, type: Phone}) == PhoneInput
    assert FormInput.module(attribute(Ash.Type.String)) == nil
  end

  test "the nearest type the map names wins" do
    configure(%{Phone => PhoneInput, MobilePhone => MobileInput})

    assert FormInput.module(attribute(MobilePhone)) == MobileInput
    assert FormInput.module(attribute(Phone)) == PhoneInput
  end

  test "false turns a type's input off, and stops the walk there" do
    configure(%{Phone => PhoneInput, MobilePhone => false})

    assert FormInput.module(attribute(MobilePhone)) == nil
    assert FormInput.module(attribute(Phone)) == PhoneInput
  end

  test "a key may be a short name Ash resolves" do
    configure(%{string: PhoneInput})

    assert FormInput.module(attribute(Ash.Type.String)) == PhoneInput
    assert FormInput.module(attribute(MobilePhone)) == PhoneInput
  end

  test "a list matches only a list key" do
    configure(%{Phone => PhoneInput})
    assert FormInput.module(attribute({:array, Phone})) == nil

    configure(%{{:array, Phone} => PhoneInput})
    assert FormInput.module(attribute({:array, MobilePhone})) == PhoneInput
    assert FormInput.module(attribute(Phone)) == nil
  end

  test "money gets AshQuick's own input, which false turns off" do
    Application.delete_env(:ash_quick, :form_inputs)
    assert FormInput.module(attribute(AshMoney.Types.Money)) == AshQuick.FormInput.Money

    configure(%{AshMoney.Types.Money => false})
    assert FormInput.module(attribute(AshMoney.Types.Money)) == nil
  end

  test "a relationship is never matched" do
    configure(%{string: PhoneInput})

    assert FormInput.module(%Ash.Resource.Relationships.BelongsTo{name: :owner}) == nil
  end

  test "a value that is no input is refused, naming it" do
    configure(%{Phone => Enum})

    assert_raise ArgumentError, ~r/names Enum for .*Phone, which defines no render\/1/, fn ->
      FormInput.module(attribute(Phone))
    end

    configure(%{Phone => "PhoneInput"})

    assert_raise ArgumentError, ~r/a value is a module implementing AshQuick.FormInput/, fn ->
      FormInput.module(attribute(Phone))
    end

    configure([{Phone, PhoneInput}])

    assert_raise ArgumentError, ~r/must be a map/, fn ->
      FormInput.module(attribute(Phone))
    end
  end
end
