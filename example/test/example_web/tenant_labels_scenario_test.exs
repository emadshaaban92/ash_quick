defmodule ExampleWeb.TenantLabelsScenarioTest do
  @moduledoc """
  A record's display label is loaded wherever a page names the record: its
  details header and title, a field linking it from a list or a details page,
  a dropdown's options and the records a form has picked, and a print's
  filename. A label that is an aggregate over records held per tenant can only
  be counted by a reader with a tenant, so a reader with none gets the record's
  id in its place, and the page still opens.

  The bins of `Example.Test.CountedLabels` are labelled by how many items the
  reader's store keeps in them; a box is put in a bin and packed with spare
  ones.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.CountedLabels.{Bin, Box, Item}

  # `%y-%m-%d-%H-%M-%S`, the moment the print was rendered.
  @stamp ~S"-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}\.pdf"

  setup %{admin: admin} do
    store = store(actor: admin)
    bin = Ash.create!(Bin, %{code: unique("B")})
    for _ <- 1..2, do: Ash.create!(Item, %{bin_id: bin.id}, tenant: store.id)
    box = Ash.create!(Box, %{code: unique("X"), bin_id: bin.id, spares: [bin.id]})
    inner = Ash.create!(Box, %{code: unique("X"), parent_id: box.id})

    %{store: store, bin: bin, box: box, inner: inner}
  end

  describe "a reader in a store" do
    setup %{conn: conn, admin: admin, store: store} do
      %{conn: log_in(conn, user(:admin, store: store, actor: admin))}
    end

    test "sees each bin named by its count", ctx do
      %{conn: conn, bin: bin, box: box, inner: inner} = ctx
      assert_named(conn, bin, box, inner, "2")
    end
  end

  # Counting needs a tenant, and asking without one would fail the read the
  # whole page stands on.
  describe "a reader with no store" do
    setup %{conn: conn, admin: admin}, do: %{conn: log_in(conn, admin)}

    test "sees each bin named by its id, on pages that still open", ctx do
      %{conn: conn, bin: bin, box: box, inner: inner} = ctx
      assert_named(conn, bin, box, inner, bin.id)
    end
  end

  defp assert_named(conn, bin, box, inner, name) do
    # The bin's own details page: its header.
    {:ok, view, _html} = live(conn, "/test/counted_bins/#{bin.id}")
    assert cells(view, "#details-menus h1") == [name]

    # A print, named after the record it is of.
    view |> element("#details-more-actions-dropdown a", ~r/^\s*Print\s*$/) |> render_click()
    view |> form("#ash-quick-action-modal form") |> render_submit()
    assert_push_event(view, "ash_quick:pdf", %{delivery: :download} = event)
    assert event.filename =~ ~r/^#{name}_sheet#{@stamp}$/

    # A field naming the bin, in a list row and on a details page: by the
    # relationship, by an explicit path to its label, and, on the box inside
    # it, by a path through the parent box ending at the bin. The path to the
    # label draws the label itself, so with none loaded it is blank rather
    # than the id, as it is for a label that holds nothing.
    {:ok, view, _html} = live(conn, "/test/counted_boxes")
    path_label = if name == bin.id, do: "", else: name
    assert [_select, _code, ^name, ^path_label, _actions] = cells(view, ~s(tr[id="#{box.id}"] td))

    {:ok, view, _html} = live(conn, "/test/counted_boxes/#{box.id}")
    assert cells(view, ~s([data-field="bin"] dd)) == [name]
    assert cells(view, ~s([data-field="bin.item_count"] dd)) == [path_label]

    {:ok, view, _html} = live(conn, "/test/counted_boxes/#{inner.id}")
    assert cells(view, ~s([data-field="parent.bin"] dd)) == [name]

    # The dropdowns' options, and what an update form has picked.
    assert {name, nil} in (conn |> visit("/test/counted_boxes/create") |> dropdown_options("Bin"))

    session = conn |> visit("/test/counted_boxes/#{box.id}/update")
    assert {name, nil} in dropdown_options(session, "Bin")
    assert {name, nil} in dropdown_options(session, "Spare Bins")
    assert picked_tags(session, "Spare Bins") == [{name, nil}]
    assert_has(session, "#form_bin_id-picker [data-part=selection]", text: name, exact: true)
  end

  defp cells(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
