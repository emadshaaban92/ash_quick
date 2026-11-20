defmodule ExampleWeb.RelatedRecordLoadsScenarioTest do
  @moduledoc """
  A field that stops at a relationship hands its widget the whole related
  record, so every attribute of it is loaded, even when another field on the
  page reaches the same record for one of its fields only: Ash merges the two
  loads into one read, and the narrower one must not trim the record the
  other draws.

  `/test/counted_box_codes` lists a box's bin count before the bin itself,
  drawn by a widget reading the bin's code, and its details do the same one
  relationship further, through the box's parent. The count is an aggregate
  over records held per tenant, so a reader with no store leaves it out, and
  the bin is still loaded whole.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.CountedLabels.{Bin, Box, Item}

  setup %{admin: admin} do
    store = store(actor: admin)
    bin = Ash.create!(Bin, %{code: unique("B")})
    Ash.create!(Item, %{bin_id: bin.id}, tenant: store.id)
    box = Ash.create!(Box, %{code: unique("X"), bin_id: bin.id})
    inner = Ash.create!(Box, %{code: unique("X"), parent_id: box.id})

    %{store: store, bin: bin, box: box, inner: inner}
  end

  test "a reader in a store sees the bin's code beside its count", ctx do
    %{conn: conn, admin: admin, store: store} = ctx
    conn = log_in(conn, user(:admin, store: store, actor: admin))
    assert_codes(conn, ctx, "1")
  end

  test "a reader with no store sees the bin's code without a count", ctx do
    %{conn: conn, admin: admin} = ctx
    assert_codes(log_in(conn, admin), ctx, "")
  end

  defp assert_codes(conn, %{bin: bin, box: box, inner: inner}, count) do
    {:ok, view, _html} = live(conn, "/test/counted_box_codes")
    assert [_select, _code, ^count, code, _actions] = cells(view, ~s(tr[id="#{box.id}"] td))
    assert code == bin.code

    {:ok, view, _html} = live(conn, "/test/counted_box_codes/#{inner.id}")
    assert cells(view, ~s([data-field="parent.bin.item_count"] dd)) == [count]
    assert cells(view, ~s([data-field="parent.bin"] dd)) == [bin.code]
  end

  defp cells(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
