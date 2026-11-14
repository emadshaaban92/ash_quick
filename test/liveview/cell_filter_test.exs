defmodule AshQuick.LiveView.CellFilterTest do
  @moduledoc """
  What a list cell offers to filter the list by, and how the row it adds sits
  beside the filter already applied.
  """
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.CellFilter
  alias AshQuick.LiveView.CellFilter.Choice
  alias AshQuick.LiveView.CustomFilter
  alias AshQuick.LiveView.QuickField
  alias AshQuick.Test.Filter.Cell

  @timezone "Etc/UTC"

  defp field(name),
    do: Cell |> CustomFilter.filterable_fields([name]) |> List.first()

  defp offered(name, value),
    do:
      name
      |> field()
      |> CellFilter.choices(value, @timezone)
      |> Enum.map(&{&1.operator, &1.value})

  describe "choices/4" do
    test "offer Equals and Not Equals a value, as the form would hold it" do
      assert offered(:name, "Ada") == [{"equals", "Ada"}, {"not_equals", "Ada"}]
      assert offered(:count, 3) == [{"equals", "3"}, {"not_equals", "3"}]

      assert offered(:price, Decimal.new("12.50")) == [
               {"equals", "12.50"},
               {"not_equals", "12.50"}
             ]

      assert offered(:active, false) == [{"equals", "false"}, {"not_equals", "false"}]
      assert offered(:stage, :live) == [{"equals", "live"}, {"not_equals", "live"}]

      assert offered(:due, ~D[2026-11-14]) == [
               {"equals", "2026-11-14"},
               {"not_equals", "2026-11-14"}
             ]
    end

    test "offer Is Empty and Is Not Empty on an empty cell" do
      assert offered(:name, nil) == [{"is_nil", ""}, {"is_not_nil", ""}]
      assert offered(:name, "") == [{"is_nil", ""}, {"is_not_nil", ""}]
      assert offered(:tags, []) == [{"is_nil", ""}, {"is_not_nil", ""}]
    end

    test "offer nothing on an empty cell of a column without emptiness" do
      assert CellFilter.choices(field(:name), nil, @timezone, emptiness?: false) == []
      assert [_, _] = CellFilter.choices(field(:name), "a", @timezone, emptiness?: false)
    end

    test "offer Has Any Of each item of a list, once each" do
      assert offered(:tags, [:sale, :new, :sale]) == [{"has_any", ["sale"]}, {"has_any", ["new"]}]
    end

    # A timestamp to the second is no value anyone filters by; its day is.
    test "offer On Day a timestamp, the day the reader's zone puts it on" do
      at = ~U[2026-11-14 23:30:00Z]

      assert field(:at) |> CellFilter.choices(at, @timezone) |> Enum.map(&{&1.operator, &1.value}) ==
               [{"on", "2026-11-14"}]

      assert field(:at) |> CellFilter.choices(at, "Africa/Cairo") |> Enum.map(& &1.value) ==
               ["2026-11-15"]
    end

    # The filter compares a float only by range.
    test "offer nothing on a float" do
      assert offered(:ratio, 0.5) == []
    end

    test "offer nothing for a value a field policy hides" do
      assert offered(:name, %Ash.ForbiddenField{field: :name, type: :attribute}) == []
    end

    test "offer nothing on a field the filter does not offer" do
      assert field(:pin) == nil
      assert CellFilter.choices(nil, "1234", @timezone) == []
    end
  end

  describe "columns/4" do
    test "are the columns showing a field the filter offers, by their data field" do
      fields =
        Enum.map([:name, :ratio, :pin, [ledger: :name], [ledger: :pin]], &QuickField.normalize/1)

      columns = CellFilter.columns(fields, Cell, [:name, :ratio, {:ledger, :name}])

      assert columns |> Map.keys() |> Enum.sort() == ["ledger.name", "name", "ratio"]
      assert columns["ledger.name"].filter_field.name == "ledger.name"
      assert columns["name"].emptiness?
    end

    test "offer no emptiness on a column a field policy partly hides" do
      fields = Enum.map([:name, :due], &QuickField.normalize/1)

      columns = CellFilter.columns(fields, Cell, [:name, :due], ["due"])

      assert columns["name"].emptiness?
      refute columns["due"].emptiness?
    end

    # Named outright in `filterable:`, a sensitive field is still no field
    # the filter offers, so its column draws no menu.
    test "leave out a sensitive field, even one named" do
      fields = Enum.map([:pin, [ledger: :pin]], &QuickField.normalize/1)

      assert CellFilter.columns(fields, Cell, [:pin, {:ledger, :pin}]) == %{}
    end

    test "are none when the list offers no filter" do
      fields = [QuickField.normalize(:name)]

      assert CellFilter.columns(fields, Cell, []) == %{}
      assert CellFilter.columns(fields, Cell, nil) == %{}
    end
  end

  describe "row/2" do
    test "names the column's field" do
      row = CellFilter.row(%Choice{kind: :only, operator: "equals", value: "x"}, field(:name))

      assert %CustomFilter{field_name: "name", operator: "equals", value: "x", path: nil} = row
    end
  end

  describe "CustomFilter.and_also/2" do
    defp leaf(name, value),
      do: %CustomFilter{
        uuid: Ash.UUID.generate(),
        field_name: name,
        operator: "equals",
        value: value
      }

    defp root(operator, children),
      do: %CustomFilter{uuid: Ash.UUID.generate(), operator: operator, children: children}

    test "makes the row the whole filter when there was none" do
      row = leaf("name", "a")

      assert %CustomFilter{operator: "and", children: [^row]} = CustomFilter.and_also(nil, row)

      assert %CustomFilter{operator: "and", children: [^row]} =
               CustomFilter.and_also(root("or", []), row)
    end

    test "adds the row to an And root" do
      old = leaf("name", "a")
      row = leaf("count", "1")

      assert %CustomFilter{operator: "and", children: [^old, ^row]} =
               CustomFilter.and_also(root("and", [old]), row)
    end

    test "adds no row an And root holds already" do
      filter = root("and", [leaf("name", "a")])

      assert CustomFilter.and_also(filter, leaf("name", "a")) == filter
    end

    # Under the Or, the row would widen the list rather than narrow it.
    test "puts an Or root in a group beside the row, under a new And root" do
      old = root("or", [leaf("name", "a"), leaf("name", "b")])
      row = leaf("count", "1")

      assert %CustomFilter{operator: "and", children: [^old, ^row]} =
               CustomFilter.and_also(old, row)
    end
  end
end
