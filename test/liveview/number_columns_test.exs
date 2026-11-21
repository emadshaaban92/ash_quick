defmodule AshQuick.LiveView.NumberColumnsTest do
  @moduledoc """
  Which of a list's columns hold numbers, and so are drawn against the
  column's right edge.
  """
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.NumberColumns
  alias AshQuick.LiveView.QuickField
  alias AshQuick.Test.Filter.Cell
  alias AshQuick.Test.Filter.Typed

  defmodule Item do
    @moduledoc "A line of a crate."
    use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
      attribute :label, :string, public?: true
      attribute :qty, :integer, public?: true
      attribute :crate_id, :uuid, public?: true
    end

    actions do
      defaults [:read]
    end
  end

  defmodule Crate do
    @moduledoc "A record whose numbers are aggregates and a calculation."
    use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
      attribute :n, :integer, public?: true
    end

    relationships do
      has_many :items, AshQuick.LiveView.NumberColumnsTest.Item, public?: true
    end

    aggregates do
      count :item_count, :items, public?: true
      sum :qty_total, :items, :qty, public?: true
      first :first_label, :items, :label, public?: true
    end

    calculations do
      calculate :double, :integer, expr(n * 2), public?: true
    end

    actions do
      defaults [:read]
    end
  end

  defmodule Box do
    @moduledoc "A record holding numbers on a related record, and in a list."
    use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
      attribute :sizes, {:array, :integer}, public?: true
    end

    relationships do
      belongs_to :cell, Cell, public?: true
      belongs_to :crate, AshQuick.LiveView.NumberColumnsTest.Crate, public?: true
    end

    actions do
      defaults [:read]
    end
  end

  defp columns(resource, specs),
    do: NumberColumns.columns(Enum.map(specs, &QuickField.normalize(&1, resource)), resource)

  test "names the columns holding an integer, a decimal or a float" do
    assert columns(Cell, [:name, :count, :price, :ratio, :active, :due, :at]) ==
             ["count", "price", "ratio"]
  end

  test "leaves out a fixed set of values, a list and text" do
    assert columns(Cell, [:stage, :tags, :pin]) == []
    assert columns(Box, [:sizes]) == []
  end

  test "reads a type of the host's own as the type it is built on" do
    assert columns(Typed, [:body, :stage, :count]) == ["count"]
  end

  test "names a count, a sum and a calculation holding a number" do
    assert columns(Crate, [:n, :item_count, :qty_total, :first_label, :double]) ==
             ["n", "item_count", "qty_total", "double"]
  end

  test "follows a relationship path to the field it reaches" do
    assert columns(Box, [[cell: :count], [cell: :name], :cell]) == ["cell.count"]
    assert columns(Box, [{[cell: :price], label: "Price"}]) == ["cell.price"]

    assert columns(Box, [[crate: :item_count], [crate: :qty_total], [crate: :first_label]]) ==
             ["crate.item_count", "crate.qty_total"]
  end

  test "leaves a column drawn by a widget as the widget draws it" do
    assert columns(Cell, [{:count, widget: &inspect/1}]) == []
  end
end
