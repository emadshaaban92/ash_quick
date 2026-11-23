defmodule ExampleWeb.UpdateFormRowsScenarioTest do
  @moduledoc """
  An update form over an embedded list drawn as sub-forms opens with the
  record's rows, beside a list argument the form fills from the record.

  `Example.Test.ShapedOrders.update` takes `:lines`, an embedded array, and
  `:tag_ids`, an argument managed onto a many-to-many, which the form fills
  with the record's tags as it opens. `Example.Test.ShapedOrdersLive.Quick`
  draws the lines for a bundle.
  """
  use ExampleWeb.FeatureCase, async: true

  require Ash.Query

  alias Example.Test.ShapedOrders
  alias Example.Test.ShapedOrders.Tag

  @form "form[phx-submit=save]"

  setup %{conn: conn, admin: admin} do
    tag = Ash.create!(Tag, %{name: unique("Tag")}, authorize?: false)
    {:ok, conn: log_in(conn, admin), tag: tag}
  end

  test "opens with the record's rows and its tags", %{conn: conn, tag: tag} do
    record = create(lines: [%{name: "First"}, %{name: "Second"}], tag_ids: [tag.id])
    {:ok, view, _html} = live(conn, "/test/shaped_orders/#{record.id}/update")

    assert row_value(view, 0) == "First"
    assert row_value(view, 1) == "Second"

    assert view
           |> element("input[type=hidden][name='form[tag_ids][]'][value='#{tag.id}']")
           |> has_element?()
  end

  test "saved as it opens, keeps the record's rows and its tags", %{conn: conn, tag: tag} do
    record = create(lines: [%{name: "First"}, %{name: "Second"}], tag_ids: [tag.id])
    {:ok, view, _html} = live(conn, "/test/shaped_orders/#{record.id}/update")

    view |> form(@form) |> render_submit()

    saved = order(record.code)
    assert Enum.map(saved.lines, & &1.name) == ["First", "Second"]
    assert Enum.map(saved.tags, & &1.id) == [tag.id]
  end

  test "an edited row is saved beside the others", %{conn: conn, tag: tag} do
    record = create(lines: [%{name: "First"}, %{name: "Second"}], tag_ids: [tag.id])
    {:ok, view, _html} = live(conn, "/test/shaped_orders/#{record.id}/update")

    view
    |> form(@form, %{"form" => %{"lines" => %{"1" => %{"name" => "Changed"}}}})
    |> render_submit()

    assert Enum.map(order(record.code).lines, & &1.name) == ["First", "Changed"]
  end

  defp create(attrs) do
    attrs = attrs |> Map.new() |> Map.merge(%{code: unique("O"), kind: :bundle})
    Ash.create!(ShapedOrders, attrs, authorize?: false)
  end

  defp row_value(view, index) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{@form} input[name='form[lines][#{index}][name]']")
    |> Enum.flat_map(&LazyHTML.attribute(&1, "value"))
    |> List.first()
  end

  defp order(code) do
    ShapedOrders
    |> Ash.Query.filter(code == ^code)
    |> Ash.Query.load(:tags)
    |> Ash.read_one!(authorize?: false)
  end
end
