defmodule ExampleWeb.FormScenarioTest do
  @moduledoc """
  The generated form, past the happy path the create flow already covers.

  A QuickView writes no form. Which inputs appear comes from the action's
  `accept` list and each field's Ash type; which of them this actor may fill in
  comes from `field_restrictions`; and whether the save lands at all comes from
  the resource's validations and its optimistic lock.

  The lock is the part that only a page can test. Losing a concurrent write is
  silent — the second save simply overwrites the first and neither person is
  told — so a lock is worth having exactly insofar as it *surfaces*, which is
  not a question an action-level test can ask.
  """
  use ExampleWeb.FeatureCase, async: true

  require Ash.Query

  alias Example.Catalog.{Brand, Product}
  alias Example.Test.PlainBrand

  setup %{admin: admin} do
    brand = brand(name: "Northwind Outfitters", actor: admin)
    category = category(name: "Tents", actor: admin)

    %{
      brand: brand,
      category: category,
      product: product(name: "Four-season tent", brand: brand, category: category, actor: admin)
    }
  end

  describe "a refused save" do
    test "says what was wrong and leaves the record alone", ctx do
      %{conn: conn, admin: admin, product: product} = ctx

      conn
      |> log_in(admin)
      |> visit(~p"/products/#{product.id}/update")
      |> fill_in("Name", with: "")
      |> click_button("Save")
      # Still on the form, with the reason beside the field rather than a flash
      # that says something went wrong.
      # An error that names an input renders *at* that input rather than as a
      # toast — `flash_form_errors/2` flashes only the ones filed under
      # `:_form`, which name no field to sit beside.
      |> assert_has("[phx-feedback-for='form[name]'], .text-error", text: "is required")
      |> refute_has("#flash-error")
      |> assert_has("form[id='#{product.id}-form']")

      assert Ash.reload!(product, authorize?: false).name == "Four-season tent"
    end

    test "a duplicate on a unique identity is refused the same way", ctx do
      %{conn: conn, admin: admin, product: product} = ctx

      taken = product(name: "Two-person tent", actor: admin)

      conn
      |> log_in(admin)
      |> visit(~p"/products/#{product.id}/update")
      |> fill_in("Sku", with: taken.sku)
      |> click_button("Save")
      |> assert_has("*", text: "Sku has already been taken")
      |> refute_has("*", text: "Input Invalid")
      |> assert_has("form[id='#{product.id}-form']")

      assert Ash.reload!(product, authorize?: false).sku != taken.sku
    end
  end

  describe "a second create action on the same resource" do
    test "is reached by ?action=, and its form offers only what it accepts", ctx do
      %{conn: conn, admin: admin, brand: brand, category: category} = ctx

      # `quick_view/3` serves no `/<action>` route, so the query parameter is the
      # only way to a create action that is not the default one.
      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products/create?action=quick_add")

      # `:quick_add` accepts sku, name, price and the two relationships — and
      # not description or tags, which the generic create form does offer.
      session
      |> assert_has("label", text: "Sku")
      |> assert_has("label", text: "Price")
      |> refute_has("label", text: "Description")
      |> refute_has("label", text: "Tags")

      # And the generic form does offer them, so the refutals above are about
      # the action's accept list rather than about those inputs never rendering.
      conn
      |> log_in(admin)
      |> visit(~p"/products/create")
      |> assert_has("label", text: "Description")
      |> assert_has("label", text: "Tags")

      sku = unique("SKU")

      session
      |> fill_in("Sku", with: sku)
      |> fill_in("Name", with: "Quick-added tent")
      |> fill_in("Price", with: "99.00")
      |> select_entry("Brand", brand.name)
      |> select_entry("Category", category.name)
      |> click_button("Save")

      created = by_sku(sku)
      assert created.name == "Quick-added tent"
      assert created.brand_id == brand.id

      # Recorded under the action that ran, not under "create" — which is the
      # reason to have a second create action at all.
      assert audited_actions(created.id) == [:quick_add]
    end
  end

  describe "the input a field's type produces" do
    test "is chosen from the Ash type, with nothing said about it on the view", ctx do
      %{conn: conn, admin: admin, product: product} = ctx

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products/#{product.id}/update")
        # `:text` rather than `:string`, which is a difference entirely about
        # the surface — a `:string` field beside it is a one-line input.
        |> assert_has("textarea[name='form[description]']")
        |> assert_has("input[type='text'][name='form[name]']")
        # `:money` keeps the currency it was stored with, formatted rather than
        # rendered as the decimal underneath.
        |> assert_has("input[name='form[price]'][value='$10.00']")

      # An array of atoms offers exactly the values its `one_of` constraint
      # names, humanized — nothing spells them out on the view or the form.
      assert dropdown_entries(session, "Tags") == ["New", "Sale", "Clearance", "Staff Pick"]
    end

    test "an array of atoms saves the values that were picked", ctx do
      %{conn: conn, admin: admin, product: product} = ctx

      conn
      |> log_in(admin)
      |> visit(~p"/products/#{product.id}/update")
      |> select_entry("Tags", "Sale")
      |> click_button("Save")

      assert Ash.reload!(product, authorize?: false).tags == [:sale]
    end
  end

  describe "a restricted field" do
    test "is absent from the form of an actor the check refuses", ctx do
      %{conn: conn, admin: admin, editor: editor, product: product} = ctx

      # `restrict :price, RoleIsAdminOnly, on: [:update]`. The editor may update
      # the product — every other input is there — and has no Price to fill in.
      conn
      |> log_in(editor)
      |> visit(~p"/products/#{product.id}/update")
      |> assert_has("label", text: "Name")
      |> refute_has("label", text: "Price")

      # The admin's form of the same action does offer it, so the refutal is
      # about the check rather than about the field never rendering.
      conn
      |> log_in(admin)
      |> visit(~p"/products/#{product.id}/update")
      |> assert_has("label", text: "Price")
    end

    test "is dropped from the changeset when the payload carries it anyway", ctx do
      %{conn: conn, editor: editor, product: product} = ctx

      was = Ash.reload!(product, authorize?: false).price

      # A missing input stops nobody from putting the key in the payload. The
      # submit below is exactly what someone adding the field in DevTools would
      # send, and the name beside it lands — so the save really ran and the one
      # value that did not change is the restricted one.
      conn
      |> log_in(editor)
      |> visit(~p"/products/#{product.id}/update")
      |> unwrap(fn view ->
        view
        |> form("form[id='#{product.id}-form']", %{"form" => %{"name" => "Forged"}})
        |> render_submit(%{"form" => %{"price" => "1.00"}})
      end)

      saved = Ash.reload!(product, authorize?: false)
      assert saved.name == "Forged"
      assert saved.price == was
    end
  end

  describe "the optimistic lock" do
    test "the second of two concurrent editors is told the record moved", ctx do
      %{conn: conn, admin: admin, brand: brand} = ctx

      # Two tabs left open on the same record. Each form holds it as it was at
      # version 1.
      first = conn |> log_in(admin) |> visit(~p"/brands/#{brand.id}/update")
      second = conn |> log_in(admin) |> visit(~p"/brands/#{brand.id}/update")

      first
      |> fill_in("Name", with: "Renamed by the first")
      |> click_button("Save")
      |> assert_has("h1", text: "Renamed by the first")

      second
      |> fill_in("Name", with: "Renamed by the second")
      |> click_button("Save")
      |> assert_has("*", text: AshQuick.LiveView.ActionErrors.stale_message())

      # The first write stands; the second never landed.
      reloaded = Ash.reload!(brand, authorize?: false)
      assert reloaded.name == "Renamed by the first"
      assert reloaded.version == 2
    end

    test "an editor working alone is never blocked", ctx do
      %{conn: conn, admin: admin, brand: brand} = ctx

      conn
      |> log_in(admin)
      |> visit(~p"/brands/#{brand.id}/update")
      |> fill_in("Name", with: "Renamed once")
      |> click_button("Save")
      |> assert_has("h1", text: "Renamed once")
      |> refute_has("*", text: AshQuick.LiveView.ActionErrors.stale_message())
    end

    test "is what the declaration switches on, not something updating a record does", ctx do
      %{brand: brand} = ctx

      assert AshQuick.Info.versioning?(Brand)
      refute AshQuick.Info.versioning?(PlainBrand)

      # The same row, held twice, written twice — through the resource that
      # declares no versioning. Both land, and the counter the other resource
      # locks on is untouched.
      held = Ash.get!(PlainBrand, brand.id, authorize?: false)

      Ash.update!(held, %{name: "First through the plain resource"}, authorize?: false)
      Ash.update!(held, %{name: "Second through the plain resource"}, authorize?: false)

      reloaded = Ash.reload!(brand, authorize?: false)
      assert reloaded.name == "Second through the plain resource"
      assert reloaded.version == 1
    end

    test "a write that only touches bookkeeping does not bump the counter", ctx do
      %{admin: admin, brand: brand} = ctx

      # `AshQuick.Versioning` derives its ignore list from the `bookkeeping`
      # declaration, so a save that changed nothing a reader would notice leaves
      # the lock where it was — two tabs that both merely re-saved do not lock
      # each other out.
      Ash.update!(brand, %{name: brand.name}, actor: admin)

      assert Ash.reload!(brand, authorize?: false).version == 1
    end
  end

  defp by_sku(sku) do
    Product
    |> Ash.Query.filter(sku == ^sku)
    |> Ash.read_one!(authorize?: false)
  end

  # Sorted: the caller asserts this as a list, and a read that names no sort is
  # returned in whatever order Postgres finds the rows. `AuditLog` has a
  # `uuid_v7` primary key, so `id: :asc` is the order the writes happened in.
  defp audited_actions(record_id) do
    Example.Accounts.AuditLog
    |> Ash.Query.filter(resource_id == ^record_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.action_name)
  end
end
