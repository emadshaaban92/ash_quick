defmodule AshQuick.FormStateTest do
  @moduledoc """
  `AshQuick.FormState` over a form of `Example.Test.ShapedOrders`, without a
  page: what it is built with, what its functions change and what AshQuick
  takes back from a hook.
  """
  use ExUnit.Case, async: true

  alias AshQuick.FormState
  alias Example.Test.ShapedOrders

  defp state(params \\ %{}, previous \\ nil) do
    ShapedOrders
    |> AshPhoenix.Form.for_create(:create)
    |> AshPhoenix.Form.validate(params, errors: false)
    |> FormState.new(:validate, scope: %{}, previous: previous)
  end

  test "is built from the fields the form draws, in order" do
    state = state()

    assert Enum.map(state.fields, & &1.name) == [
             :code,
             :kind,
             :discount_reason,
             :gift_note,
             :lines,
             :price
           ]

    assert %{kind: :choice, required?: true, inputs: [:kind]} = FormState.field(state, :kind)

    assert %{kind: :text, required?: false, label: "Gift Note"} =
             FormState.field(state, :gift_note)

    assert %{kind: :nested, inputs: [:lines]} = FormState.field(state, :lines)
    assert FormState.field(state, :locked_code) == nil
  end

  test "reads values as Ash cast them" do
    assert FormState.value(state(%{"kind" => "gift"}), :kind) == :gift
    assert FormState.value(state(), :kind) == :standard
  end

  test "says what changed since the state before it" do
    first = state(%{"kind" => "gift"})
    assert FormState.changed?(first, :kind)

    second = state(%{"kind" => "gift", "code" => "A"}, first)
    refute FormState.changed?(second, :kind)
    assert FormState.changed?(second, :code)
  end

  test "hides, requires, disables and relabels" do
    state =
      state()
      |> FormState.hide(:gift_note)
      |> FormState.hide(:lines)
      |> FormState.hide(:discount_reason, false)
      |> FormState.require(:discount_reason)
      |> FormState.disable(:code)
      |> FormState.put_label(:kind, "Order kind")
      |> FormState.put_help(:kind, "Pick one")
      |> FormState.put_attrs(:code, placeholder: "A-1")

    assert Enum.map(FormState.visible_fields(state), & &1.name) ==
             [:code, :kind, :discount_reason, :price]

    assert %{disabled?: true, attrs: [placeholder: "A-1"]} = FormState.field(state, :code)
    assert %{label: "Order kind", help: "Pick one"} = FormState.field(state, :kind)
    assert %{required?: true} = FormState.field(state, :discount_reason)

    assert Enum.sort(FormState.dropped_params(state)) ==
             Enum.sort(~w(code _unused_code gift_note _unused_gift_note lines _unused_lines))

    shown = FormState.show(state, :gift_note)
    assert :gift_note in Enum.map(FormState.visible_fields(shown), & &1.name)
  end

  test "refuses a name it has no field for, and names those it has" do
    error = assert_raise ArgumentError, fn -> FormState.hide(state(), :gift_notes) end
    assert error.message =~ ":gift_notes"
    assert error.message =~ ":gift_note,"

    assert_raise ArgumentError, fn -> FormState.show(state(), :locked_code) end
    assert_raise ArgumentError, fn -> FormState.value(state(), :locked_code) end
  end

  test "takes only the flags back from a hook, never a field or an optional required one" do
    built = state()
    locked = Ash.Resource.Info.attribute(ShapedOrders, :locked_code)

    returned = %{
      built
      | fields:
          Enum.map(built.fields, fn
            %{name: :code} = field -> %{field | required?: false, hidden?: true}
            field -> field
          end) ++
            [
              %FormState.Field{
                name: :locked_code,
                inputs: [:locked_code],
                kind: :text,
                label: "Locked",
                source: locked
              }
            ]
    }

    narrowed = FormState.narrow(built, returned)

    assert Enum.map(narrowed.fields, & &1.name) == Enum.map(built.fields, & &1.name)
    assert %{required?: true, hidden?: true} = FormState.field(narrowed, :code)

    assert_raise ArgumentError, ~r/must return an AshQuick.FormState/, fn ->
      FormState.narrow(built, :ok)
    end
  end
end
