defmodule AshQuick.LiveView.EnumOptionsTest do
  @moduledoc """
  The options and labels a field with a fixed set of values offers: an
  `Ash.Type.Enum` speaks for itself, an atom with `one_of` is humanized, and
  anything else holds no fixed set.
  """
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.EnumOptions

  defmodule Stage do
    @moduledoc false
    use Ash.Type.Enum,
      values: [draft: [label: "Being written"], live: [label: "On air"], done: "Over"]
  end

  defmodule WrappedStage do
    @moduledoc false
    use Ash.Type.NewType, subtype_of: Stage
  end

  defmodule Size do
    @moduledoc false
    use Ash.Type.NewType, subtype_of: :atom, constraints: [one_of: [:small, :extra_large]]
  end

  # Constraints as an attribute holds them: a new type's own are merged in as
  # the resource compiles.
  defp field(type, constraints \\ []) do
    {:ok, constraints} = Ash.Type.init(type, constraints)
    %{type: type, constraints: constraints}
  end

  describe "kind/1" do
    test "an enum, an atom with one_of and a new type over either are picked from a set" do
      for type <- [Stage, WrappedStage, Size] do
        assert EnumOptions.kind(field(type)) == :single
        assert EnumOptions.kind(field({:array, type})) == :array
      end

      assert EnumOptions.kind(field(Ash.Type.Atom, one_of: [:a])) == :single
      assert EnumOptions.kind(field({:array, Ash.Type.Atom}, items: [one_of: [:a]])) == :array
    end

    test "a plain atom, any other type and no field at all are not" do
      assert EnumOptions.kind(field(Ash.Type.Atom)) == nil
      assert EnumOptions.kind(field({:array, Ash.Type.Atom})) == nil
      assert EnumOptions.kind(field(Ash.Type.String)) == nil
      assert EnumOptions.kind(%{type: :has_many}) == nil
      assert EnumOptions.kind(nil) == nil
    end
  end

  describe "options/1" do
    test "an enum offers its values under its own labels, in its order" do
      expected = [{"Being written", :draft}, {"On air", :live}, {"Done", :done}]

      assert EnumOptions.options(field(Stage)) == expected
      assert EnumOptions.options(field({:array, Stage})) == expected
      assert EnumOptions.options(field(WrappedStage)) == expected
    end

    test "an atom offers its one_of values humanized" do
      assert EnumOptions.options(field(Ash.Type.Atom, one_of: [:small, :extra_large])) ==
               [{"Small", :small}, {"Extra Large", :extra_large}]

      assert EnumOptions.options(field(Size)) == [
               {"Small", :small},
               {"Extra Large", :extra_large}
             ]
    end

    test "a field without a fixed set offers nothing" do
      assert EnumOptions.options(field(Ash.Type.Atom)) == []
    end
  end

  describe "search/2" do
    test "matches what the label says, anywhere in it and in any case" do
      options = EnumOptions.options(field(Stage))

      assert EnumOptions.search(options, "AIR") == [{"On air", :live}]
      assert EnumOptions.search(options, "writ") == [{"Being written", :draft}]
      assert EnumOptions.search(options, "liv") == []
      assert EnumOptions.search(options, "") == options
      assert EnumOptions.search(options, nil) == options
    end
  end

  describe "label/2" do
    test "an enum's value reads its label, alone or in a list" do
      assert EnumOptions.label(field(Stage), :live) == "On air"
      assert EnumOptions.label(field({:array, Stage}), :live) == "On air"
    end

    test "a value the enum no longer lists, and any other atom, is humanized" do
      assert EnumOptions.label(field(Stage), :retired) == "Retired"
      assert EnumOptions.label(field(Ash.Type.Atom), :extra_large) == "Extra Large"
      assert EnumOptions.label(nil, :extra_large) == "Extra Large"
    end
  end
end
