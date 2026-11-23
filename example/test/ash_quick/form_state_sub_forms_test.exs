defmodule AshQuick.FormStateSubFormsTest do
  @moduledoc """
  The sub-form states of an `AshQuick.FormState`, over a form of
  `Example.Test.ShapedBundles`, without a page: how they are held, what
  `update_each/3` and `sub_forms/2` reach and what AshQuick takes back.
  """
  use ExUnit.Case, async: true

  alias AshQuick.FormState
  alias AshQuick.LiveView.Utils
  alias Example.Test.ShapedBundles

  @params %{
    "channel" => "wholesale",
    "items" => %{
      "0" => %{"kind" => "device", "parts" => %{"0" => %{"name" => "Fan"}, "1" => %{}}},
      "1" => %{"kind" => "service"}
    },
    "shipping" => %{"country" => "US"}
  }

  defp state(params \\ @params) do
    ShapedBundles
    |> AshPhoenix.Form.for_create(:create, forms: Utils.nested_forms(ShapedBundles, :create, []))
    |> AshPhoenix.Form.add_form("form[shipping]", validate?: false)
    |> AshPhoenix.Form.validate(params, errors: false)
    |> FormState.new(:validate, scope: %{})
  end

  test "holds a state per sub-form, by field, in the order they are drawn" do
    state = state()

    assert [line0, line1] = state.forms.items
    assert line0.form.name == "form[items][0]"
    assert line1.form.name == "form[items][1]"
    assert FormState.value(line0, :kind) == :device
    assert FormState.value(line1, :kind) == :service

    assert [part0, part1] = line0.forms.parts
    assert part0.form.name == "form[items][0][parts][0]"
    assert FormState.value(part0, :name) == "Fan"
    assert part1.parent.form.name == "form[items][0]"
    assert line1.forms.parts == []

    assert [shipping] = state.forms.shipping
    assert FormState.value(shipping, :country) == "US"
  end

  test "sub_forms/2 reaches the states at a path" do
    state = state()

    assert state |> FormState.sub_forms([:items]) |> Enum.map(& &1.form.name) ==
             ["form[items][0]", "form[items][1]"]

    assert state |> FormState.sub_forms([:items, :parts]) |> Enum.map(& &1.form.name) ==
             ["form[items][0][parts][0]", "form[items][0][parts][1]"]
  end

  test "update_each/3 runs a rule for every row, with the parent as it stands" do
    state =
      state()
      |> FormState.put_label(:channel, "Sold")
      |> FormState.update_each([:items], fn item ->
        assert %{label: "Sold"} = FormState.field(item.parent, :channel)
        assert FormState.value(item.parent, :channel) == :wholesale

        FormState.hide(item, :serial, FormState.value(item, :kind) != :device)
      end)
      |> FormState.update_each([:items, :parts], &FormState.disable(&1, :name))

    assert [%{hidden?: false}, %{hidden?: true}] =
             state |> FormState.sub_forms([:items]) |> Enum.map(&FormState.field(&1, :serial))

    assert [%{disabled?: true}, %{disabled?: true}] =
             state
             |> FormState.sub_forms([:items, :parts])
             |> Enum.map(&FormState.field(&1, :name))
  end

  test "update_each/3 refuses a name that is no input, one that is no sub-form, and a non-state" do
    state = state()

    assert_raise ArgumentError, ~r/has no field :itemz/, fn ->
      FormState.update_each(state, [:itemz], & &1)
    end

    assert_raise ArgumentError, ~r/:channel .* is not drawn as sub-forms/, fn ->
      FormState.update_each(state, [:channel], & &1)
    end

    assert_raise ArgumentError, ~r/must return an AshQuick.FormState/, fn ->
      FormState.update_each(state, [:items], fn _item -> :ok end)
    end

    assert_raise ArgumentError, ~r/has no field :serialz/, fn ->
      FormState.update_each(state, [:items], &FormState.hide(&1, :serialz))
    end
  end

  test "takes only the flags back from a hook's rows, and keeps the rows the form has" do
    built = state()

    returned =
      FormState.update_each(built, [:items], fn item ->
        item
        |> FormState.hide(:serial)
        |> Map.update!(:fields, &Enum.reject(&1, fn field -> field.name == :hours end))
      end)

    # A hook that drops a row, or puts junk in its place, changes nothing there.
    returned = %{returned | forms: %{returned.forms | shipping: [:junk]}}
    narrowed = FormState.narrow(built, returned)

    assert [line0, line1] = narrowed.forms.items
    assert %{hidden?: true} = FormState.field(line0, :serial)
    assert %{hidden?: true} = FormState.field(line1, :serial)
    assert %{hidden?: false} = FormState.field(line0, :hours)
    assert [%{fields: fields}] = narrowed.forms.shipping
    assert Enum.all?(fields, &(not &1.hidden?))
  end

  test "the server leaves alone the rows under a field it holds back" do
    state =
      state()
      |> FormState.update_each([:items], &FormState.hide(&1, :parts))

    assert state |> FormState.taken_sub_forms() |> Enum.map(& &1.form.name) ==
             ["form[items][0]", "form[items][1]", "form[shipping]"]

    assert FormState.find(state, "form[items][0][parts][1]").form.name ==
             "form[items][0][parts][1]"

    assert FormState.find(state, "form[items][5]") == nil
  end
end
