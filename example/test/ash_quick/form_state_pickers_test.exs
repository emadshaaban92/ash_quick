defmodule AshQuick.FormStatePickersTest do
  @moduledoc """
  `AshQuick.FormState.filter/3` and `options/3` over a form
  of `Example.Test.PickedPlaces`, without a page: what they put on a field,
  what they refuse, and what AshQuick takes back from a hook.
  """
  use ExUnit.Case, async: true

  import Ash.Expr

  alias AshQuick.FormState
  alias Example.Test.PickedPlaces

  defp state(params \\ %{}) do
    PickedPlaces
    |> AshPhoenix.Form.for_create(:create)
    |> AshPhoenix.Form.validate(params, errors: false)
    |> FormState.new(:validate, scope: %{})
  end

  test "a field starts narrowed by nothing" do
    assert %{filters: [], options: nil} = FormState.field(state(), :city)
    assert %{options: nil} = FormState.field(state(), :status)
  end

  test "filter/3 adds to the filters, call by call" do
    state =
      state()
      |> FormState.filter(:stop_ids, expr(port? == true))
      |> FormState.filter(:city, expr(name != "X"))
      |> FormState.filter(:city, expr(port? == false))

    assert [_one] = FormState.field(state, :stop_ids).filters
    assert [_one, _two] = FormState.field(state, :city).filters
  end

  test "filter/3 refuses a field that picks no records" do
    assert_raise ArgumentError, ~r/:code .* picks no records/, fn ->
      FormState.filter(state(), :code, expr(true))
    end
  end

  test "filter/3 refuses a field whose destination has no lookup action" do
    assert_raise ArgumentError, ~r/cannot search/, fn ->
      FormState.filter(state(), :owner, expr(true))
    end
  end

  test "options/3 narrows in the type's order, and a second call narrows further" do
    state = FormState.options(state(), :status, [:submitted, "draft"])
    assert FormState.field(state, :status).options == [:draft, :submitted]

    state = FormState.options(state, :status, [:submitted, :approved])
    assert FormState.field(state, :status).options == [:submitted]
  end

  test "options/3 refuses a value the type does not list, and a field of no fixed set" do
    assert_raise ArgumentError, ~r/offers no \[:lost\]/, fn ->
      FormState.options(state(), :status, [:draft, :lost])
    end

    assert_raise ArgumentError, ~r/:code .* is not one/, fn ->
      FormState.options(state(), :code, ["a"])
    end
  end

  test "options/3 reaches a sub-form's field" do
    state =
      state(%{"kind" => "cruise", "legs" => %{"0" => %{"mode" => "bus"}}})
      |> FormState.update_each([:legs], &FormState.options(&1, :mode, [:ship]))

    assert [%{options: [:ship]}] =
             state |> FormState.sub_forms([:legs]) |> Enum.map(&FormState.field(&1, :mode))
  end

  test "a hook's options are held to the values the type lists" do
    built = state()

    returned = %{
      built
      | fields:
          Enum.map(built.fields, fn
            %{name: :status} = field -> %{field | options: [:approved, :lost, "draft"]}
            %{name: :code} = field -> %{field | options: [:anything]}
            field -> field
          end)
    }

    narrowed = FormState.narrow(built, returned)
    assert FormState.field(narrowed, :status).options == [:draft, :approved]
    assert FormState.field(narrowed, :code).options == nil
  end
end
