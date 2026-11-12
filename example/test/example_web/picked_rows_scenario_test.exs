defmodule ExampleWeb.PickedRowsScenarioTest do
  @moduledoc """
  Sub-form rows that each pick from dropdowns of their own.

  `Example.Test.PickedRows.create` brings its rows along through
  `manage_relationship`, and the parent and every row pick a `kind` from a fixed
  set and a `bin` from a dropdown. Each dropdown is a component of its own, so
  each needs an id no other dropdown on the form holds: two rows, or a row and
  the parent, share their field names but not their dropdowns.
  """
  use ExampleWeb.FeatureCase, async: true

  require Ash.Query

  setup %{conn: conn, admin: admin} do
    bins =
      for name <- [unique("Bin A"), unique("Bin B")] do
        Ash.create!(Example.Test.PickedRows.Bin, %{name: name}, authorize?: false)
      end

    {:ok, conn: log_in(conn, admin), bins: bins}
  end

  # The components' ids never reach the page, so the proof is that adding the
  # rows does not crash the form: LiveView refuses two components with one id.
  test "adding two rows draws each row's dropdowns beside the parent's", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/test/picked_rows/create")

    add_row(view)
    html = add_row(view)

    # The parent's kind and bin, then each row's.
    assert html
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("div[phx-hook='LiveSelect']")
           |> Enum.count() == 6
  end

  test "a pick in the second row lands in that row, not in the first or the parent's", %{
    conn: conn,
    bins: [_bin_a, bin_b]
  } do
    {:ok, view, _html} = live(conn, "/test/picked_rows/create")
    add_row(view)
    add_row(view)

    pick(view, "form_rows_1_kind", "Large")
    html = pick(view, "form_rows_1_bin", bin_b.name)

    assert hidden_value(html, "form[rows][1][kind]") == "large"
    assert hidden_value(html, "form[rows][1][bin_id]") == bin_b.id
    assert hidden_value(html, "form[rows][0][kind]") in [nil, ""]
    assert hidden_value(html, "form[rows][0][bin_id]") in [nil, ""]
    assert hidden_value(html, "form[kind]") in [nil, ""]
    assert hidden_value(html, "form[bin_id]") in [nil, ""]

    code = unique("R")

    view
    |> form("form[phx-submit=save]", %{"form" => %{"code" => code}})
    |> render_submit()

    [saved] =
      Example.Test.PickedRows
      |> Ash.Query.filter(code == ^code)
      |> Ash.Query.load(:rows)
      |> Ash.read!(authorize?: false)

    assert saved.kind == nil
    assert saved.bin_id == nil

    assert saved.rows |> Enum.map(&{&1.kind, &1.bin_id}) |> Enum.sort() ==
             Enum.sort([{nil, nil}, {:large, bin_b.id}])
  end

  defp add_row(view) do
    view
    |> element("button[phx-click=add-form][phx-value-path='form[rows]']")
    |> render_click()
  end

  # Picks the entry labelled `entry` from the dropdown over the form field
  # whose id is `field_id`, by opening it the way a click on it does.
  defp pick(view, field_id, entry) do
    dropdown = "div[phx-hook='LiveSelect']:has(input[type='text'][id^='#{field_id}_'])"

    idx =
      view
      |> element("#{dropdown} > div > input[type='text']")
      |> render_click()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#{dropdown} > ul > li > div")
      |> Enum.find(&(&1 |> LazyHTML.text() |> String.contains?(entry)))
      |> LazyHTML.attribute("data-idx")
      |> List.first()

    view
    |> element(dropdown)
    |> render_hook("option_click", %{idx: idx})
  end

  defp hidden_value(html, name) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(input[type="hidden"][name="#{name}"]))
    |> Enum.flat_map(&LazyHTML.attribute(&1, "value"))
    |> List.first()
  end
end
