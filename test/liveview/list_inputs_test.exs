defmodule AshQuick.LiveView.ListInputsTest do
  @moduledoc """
  A QuickView refuses to compile a form that would offer a list it cannot
  save: one with no fixed set of values, which gets a text input posting one
  string the list refuses. Refused on the page rather than the resource,
  because only the page knows which fields a widget renders.
  """
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.QuickView.Options
  alias AshQuick.Test.ListInputs.Record

  defp options(form_opts) do
    Options.new(__MODULE__.SomeQuickView, Record, resource: Record, form: form_opts)
  end

  defp widgets(names), do: Map.new(names, &{&1, fn assigns -> assigns end})

  test "every such list on every action a page offers is named at once" do
    message = Exception.message(assert_raise(ArgumentError, fn -> options([]) end))

    assert message =~ "SomeQuickView's forms would offer"
    assert message =~ ":create takes :marks, {:array, Ash.Type.Atom}"
    assert message =~ ":retag takes :labels, {:array, Ash.Type.String}"
    assert message =~ ":retag takes :codes, {:array, AshQuick.Test.ListInputs.Mark}"
    assert message =~ ":retag takes :flags, {:array, Ash.Type.Boolean}"
    assert message =~ ":retag takes :times, {:array, Ash.Type.TimeUsec}"
    assert message =~ ":retag takes :extras, {:array, Ash.Type.Map}"
    assert message =~ "A field restriction that hides it does not count"
    assert message =~ "constraints: [items: [one_of: [:a, :b]]]"
    assert message =~ "form: [widgets: %{marks: &__MODULE__.marks_input/1}]"

    # Selects, and a private action no page offers.
    refute message =~ ":picked"
    refute message =~ ":colours"
    refute message =~ ":tags"
    # Maps, but each one a sub-form for the relationship the action manages.
    refute message =~ ":notes"
  end

  test "a list a widget renders compiles" do
    assert %Options{} =
             options(widgets: widgets([:marks, :labels, :codes, :flags, :times, :extras]))
  end

  test "one left without a widget is still refused" do
    message =
      Exception.message(
        assert_raise(ArgumentError, fn ->
          options(widgets: widgets([:marks, :labels, :flags, :times, :extras]))
        end)
      )

    assert message =~ ":retag takes :codes"
    refute message =~ ":marks"
  end
end
