defmodule ExampleWeb.PickerHintScenarioTest do
  @moduledoc """
  A relationship dropdown draws each record's display hint beside its label,
  so two records sharing a label can be told apart where one of them is
  picked.

  `Example.Catalog.Brand` hints its code, an attribute; the labels of
  `Example.Test.PickedLabels` hint a calculation, which neither the option
  read nor the update form's record load would bring without asking for it;
  the shelves of `Example.Test.ShelvedCrates` hint an aggregate that only a
  reader with a tenant can count.
  """
  use ExampleWeb.FeatureCase, async: true

  require Ash.Query

  alias Example.Catalog.Product
  alias Example.Test.PickedLabels
  alias Example.Test.PickedLabels.Label
  alias Example.Test.ShelvedCrates
  alias Example.Test.ShelvedCrates.{Item, Shelf}

  test "two brands sharing a name are told apart, and the one picked is saved", ctx do
    %{conn: conn, admin: admin} = ctx
    conn = log_in(conn, admin)
    name = unique("Brand")
    first = Ash.create!(Example.Catalog.Brand, %{code: unique("B"), name: name}, actor: admin)
    second = Ash.create!(Example.Catalog.Brand, %{code: unique("B"), name: name}, actor: admin)
    category = category(actor: admin)

    session = conn |> visit(~p"/products/create")

    options = dropdown_options(session, "Brand")
    assert {name, first.code} in options
    assert {name, second.code} in options

    sku = unique("SKU")

    session
    |> fill_in("Sku", with: sku)
    |> fill_in("Name", with: "Two-brand tent")
    |> fill_in("Price", with: "10.00")
    |> select_entry("Brand", name, hint: second.code)
    |> select_entry("Category", category.name)
    |> click_button("Save")

    [created] = Product |> Ash.Query.filter(sku == ^sku) |> Ash.read!(authorize?: false)
    assert created.brand_id == second.id

    # Closed, the update form's Brand reads which of the two it is, and open
    # it offers that brand with its hint — from the record's own load rather
    # than the option read.
    session = conn |> visit(~p"/products/#{created.id}/update")

    assert_has(
      session,
      "input[name='form[brand_id_text_input]'][value='#{name} (#{second.code})']"
    )

    assert {name, second.code} in dropdown_options(session, "Brand")
  end

  test "two labels sharing a name are offered, picked together and kept apart", ctx do
    %{conn: conn, admin: admin} = ctx
    conn = log_in(conn, admin)
    name = unique("Label")
    upper = Ash.create!(Label, %{name: name, shelf: "A"})
    lower = Ash.create!(Label, %{name: name, shelf: "B"})
    # Its hint is blank, which is no hint.
    plain = Ash.create!(Label, %{name: unique("Label")})

    session = conn |> visit("/test/picked_labels/create")

    options = dropdown_options(session, "Labels")
    assert {name, "Shelf A"} in options
    assert {name, "Shelf B"} in options
    assert {plain.name, nil} in options

    # Picking the second of two same-named labels adds it beside the first
    # rather than taking the first one back out.
    code = unique("P")

    session =
      session
      |> fill_in("Code", with: code)
      |> select_entry("Labels", name, hint: "Shelf A")
      |> select_entry("Labels", name, hint: "Shelf B")

    assert sorted_tags(session) == [{name, "Shelf A"}, {name, "Shelf B"}]

    click_button(session, "Save")

    [record] = PickedLabels |> Ash.Query.filter(code == ^code) |> Ash.read!(load: :labels)
    assert record.labels |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([upper.id, lower.id])

    session = conn |> visit("/test/picked_labels/#{record.id}/update")
    assert sorted_tags(session) == [{name, "Shelf A"}, {name, "Shelf B"}]

    # After a reconnect LiveSelect restores the tags from what the browser
    # kept of them: a label and a value each. The label still says which.
    session =
      PhoenixTest.unwrap(session, fn view ->
        view
        |> element("#form_picks_live_select_component")
        |> render_hook("selection_recovery", [
          %{"label" => "#{name} (Shelf A)", "value" => upper.id},
          %{"label" => "#{name} (Shelf B)", "value" => lower.id}
        ])
      end)

    assert sorted_tags(session) == [{"#{name} (Shelf A)", nil}, {"#{name} (Shelf B)", nil}]
  end

  describe "a hint counted per tenant" do
    setup %{admin: admin} do
      store = store(actor: admin)
      shelf = Ash.create!(Shelf, %{name: unique("Shelf")})
      for _ <- 1..2, do: Ash.create!(Item, %{shelf_id: shelf.id}, tenant: store.id)
      crate = Ash.create!(ShelvedCrates, %{code: unique("C"), shelf_id: shelf.id})

      %{store: store, shelf: shelf, crate: crate}
    end

    test "is shown to a reader in a store", ctx do
      %{conn: conn, admin: admin, store: store, shelf: shelf, crate: crate} = ctx
      conn = log_in(conn, user(:admin, store: store, actor: admin))

      assert {shelf.name, "2"} in shelf_options(conn, "/test/shelved_crates/create")
      assert {shelf.name, "2"} in shelf_options(conn, "/test/shelved_crates/#{crate.id}/update")
    end

    # Counting needs a tenant, and asking without one would fail the read the
    # whole form stands on.
    test "is left out for a reader with no store, and the forms still open", ctx do
      %{conn: conn, admin: admin, shelf: shelf, crate: crate} = ctx
      conn = log_in(conn, admin)

      assert {shelf.name, nil} in shelf_options(conn, "/test/shelved_crates/create")
      assert {shelf.name, nil} in shelf_options(conn, "/test/shelved_crates/#{crate.id}/update")
    end
  end

  # The option read loads every option's hint, so it is the read a keystroke
  # must not repeat. Shelves are read by this module alone, so counting their
  # reads counts this form's.
  test "the options are read once, not on every keystroke in the form", ctx do
    %{conn: conn, admin: admin} = ctx
    conn = log_in(conn, admin)
    Ash.create!(Shelf, %{name: unique("Shelf")})
    test_pid = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:ash, :domain, :read, :start],
      fn _event, _measurements, %{resource: resource}, _config ->
        if resource == Shelf, do: send(test_pid, :shelf_read)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, view, _html} = live(conn, "/test/shelved_crates/create")
    assert_received :shelf_read
    flush_shelf_reads()

    for text <- ["C", "Cr", "Cra"] do
      view |> form("#shelved_crates-create", form: %{code: text}) |> render_change()
    end

    refute_received :shelf_read
  end

  defp shelf_options(conn, path), do: conn |> visit(path) |> dropdown_options("Shelf")

  defp sorted_tags(session), do: session |> picked_tags("Labels") |> Enum.sort()

  defp flush_shelf_reads do
    receive do
      :shelf_read -> flush_shelf_reads()
    after
      0 -> :ok
    end
  end
end
