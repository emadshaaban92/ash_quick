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
           |> LazyHTML.query("[data-aq-picker]")
           |> LazyHTML.attribute("id") == [
             "form_kind-picker",
             "form_bin_id-picker",
             "form_rows_0_kind-picker",
             "form_rows_0_bin_id-picker",
             "form_rows_1_kind-picker",
             "form_rows_1_bin_id-picker"
           ]
  end

  test "a pick in the second row lands in that row, not in the first or the parent's", %{
    conn: conn,
    bins: [_bin_a, bin_b]
  } do
    {:ok, view, _html} = live(conn, "/test/picked_rows/create")
    add_row(view)
    add_row(view)

    pick(view, "form_rows_1_kind", "Large")
    html = pick(view, "form_rows_1_bin_id", bin_b.name)

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

  # A row's pickers are named by its index, so removing the row above hands
  # the survivor's values to the pickers the removed row drew. They name what
  # they now hold rather than keep the removed row's picks or print raw keys.
  # The second bin exists only once the first row has searched, so the
  # picker that takes it over has never seen it, and must look it up.
  test "removing the row above another keeps the survivor's picks named", %{conn: conn} do
    bin_a = Ash.create!(Example.Test.PickedRows.Bin, %{name: unique("Bin A")}, authorize?: false)
    {:ok, view, _html} = live(conn, "/test/picked_rows/create")
    add_row(view)
    add_row(view)

    pick(view, "form_rows_0_kind", "Small")
    ExampleWeb.PickerDriver.search(view, "form_rows_0_bin_id-picker", bin_a.name)
    ExampleWeb.PickerDriver.pick(view, "form_rows_0_bin_id-picker", bin_a.name)

    bin_b = Ash.create!(Example.Test.PickedRows.Bin, %{name: unique("Bin B")}, authorize?: false)
    pick(view, "form_rows_1_kind", "Large")
    ExampleWeb.PickerDriver.search(view, "form_rows_1_bin_id-picker", bin_b.name)
    ExampleWeb.PickerDriver.pick(view, "form_rows_1_bin_id-picker", bin_b.name)

    view
    |> element("button[phx-click=remove-form][phx-value-path='form[rows][0]']")
    |> render_click()

    assert ExampleWeb.PickerDriver.picked(view, "form_rows_0_kind-picker") == ["Large"]
    assert ExampleWeb.PickerDriver.picked(view, "form_rows_0_bin_id-picker") == [bin_b.name]
    refute has_element?(view, "#form_rows_1_kind-picker")

    html = render(view)
    assert hidden_value(html, "form[rows][0][kind]") == "large"
    assert hidden_value(html, "form[rows][0][bin_id]") == bin_b.id
  end

  defp add_row(view) do
    view
    |> element("button[phx-click=add-form][phx-value-path='form[rows]']")
    |> render_click()
  end

  # Picks the entry labelled `entry` from the dropdown over the form field
  # whose id is `field_id`, by opening it as a click on it does.
  defp pick(view, field_id, entry) do
    ExampleWeb.PickerDriver.search(view, "#{field_id}-picker")
    view |> ExampleWeb.PickerDriver.pick("#{field_id}-picker", entry) |> render()
  end

  defp hidden_value(html, name) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(input[type="hidden"][name="#{name}"]))
    |> Enum.flat_map(&LazyHTML.attribute(&1, "value"))
    |> List.first()
  end
end
