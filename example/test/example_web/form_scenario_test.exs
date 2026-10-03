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

  import ExUnit.CaptureLog

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

  describe "a value refused by a match/2 validation" do
    # Every error `match/2` raises carries its `%Regex{}` as a var, named by the
    # message or not, and a Regex has no `String.Chars`. Rendering the error
    # used to stringify every var, so the refusal crashed the LiveView and the
    # person never saw the message the validation was written to show.
    test "is shown, and the page is still there to correct it", %{conn: conn, admin: admin} do
      code = Integer.to_string(System.unique_integer([:positive]))

      conn
      |> log_in(admin)
      |> visit(~p"/test/digits_only/create")
      |> fill_in("Code", with: "12ab")
      |> fill_in("Name", with: "Digits")
      |> click_button("Save")
      |> assert_has("#flash-error", text: "Code must be digits")
      |> assert_has(".text-error", text: "must be digits")
      |> unwrap(fn view ->
        assert Process.alive?(view.pid)
        render(view)
      end)
      # The same page takes the corrected value, which a dead one could not.
      |> fill_in("Code", with: code)
      |> click_button("Save")
      |> refute_has("#flash-error")

      assert Example.Test.DigitsOnly
             |> Ash.read!(authorize?: false)
             |> Enum.any?(&(&1.code == code))
    end

    test "renders a regex the message names as the regex, not a crash", ctx do
      %{conn: conn, admin: admin} = ctx

      conn
      |> log_in(admin)
      |> visit(~p"/test/digits_only/create")
      |> fill_in("Code", with: "123")
      |> fill_in("Name", with: "Digits")
      |> fill_in("Ref", with: "abc")
      |> click_button("Save")
      |> assert_has("#flash-error", text: "Ref must match ~r/^[A-Z]+$/")
      |> unwrap(fn view ->
        assert Process.alive?(view.pid)
        render(view)
      end)
    end

    # Refused twice in one submit, the errors take the form's own path rather
    # than the single-attribute one: rendered beside their inputs, from vars
    # AshPhoenix has already stripped of anything it cannot stringify.
    test "is shown beside another refusal in the same submit", %{conn: conn, admin: admin} do
      conn
      |> log_in(admin)
      |> visit(~p"/test/digits_only/create")
      |> fill_in("Code", with: "12ab")
      |> click_button("Save")
      |> assert_has(".text-error", text: "must be digits")
      |> assert_has(".text-error", text: "is required")
      |> unwrap(fn view ->
        assert Process.alive?(view.pid)
        render(view)
      end)
      |> assert_has("button", text: "Save")
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

  describe "a refused save, in the log" do
    # The person is shown why a save failed, so the log is told only *what*
    # failed — resource, action, field names — and never what was submitted.
    test "names the fields that failed, not the values put in them", ctx do
      %{conn: conn, admin: admin} = ctx
      log_saves_at_debug()
      code = "#{System.unique_integer([:positive])}-not-digits"

      log =
        capture_log([level: :debug], fn ->
          conn
          |> log_in(admin)
          |> visit(~p"/test/digits_only/create")
          |> fill_in("Code", with: code)
          |> click_button("Save")
          |> assert_has(".text-error", text: "is required")
        end)

      assert log =~ "form save on Example.Test.DigitsOnly.create refused: errors on fields"
      assert log =~ "code"
      assert log =~ "name"
      refute log =~ code
      refute log =~ "AshPhoenix.Form"
    end

    test "names a single refused attribute, not its value", ctx do
      %{conn: conn, admin: admin} = ctx
      log_saves_at_debug()
      code = "#{System.unique_integer([:positive])}-not-digits"
      name = "Name #{System.unique_integer([:positive])}"

      log =
        capture_log([level: :debug], fn ->
          conn
          |> log_in(admin)
          |> visit(~p"/test/digits_only/create")
          |> fill_in("Code", with: code)
          |> fill_in("Name", with: name)
          |> click_button("Save")
          |> assert_has("#flash-error", text: "Code must be digits")
        end)

      assert log =~
               "form save on Example.Test.DigitsOnly.create refused: invalid value for field code"

      refute log =~ code
      refute log =~ name
      refute log =~ "must be digits"
    end

    test "names the resource of a stale save, not what either editor typed", ctx do
      %{conn: conn, admin: admin, brand: brand} = ctx
      log_saves_at_debug()

      first = conn |> log_in(admin) |> visit(~p"/brands/#{brand.id}/update")
      second = conn |> log_in(admin) |> visit(~p"/brands/#{brand.id}/update")

      first
      |> fill_in("Name", with: "Renamed by the first")
      |> click_button("Save")
      |> assert_has("h1", text: "Renamed by the first")

      log =
        capture_log([level: :debug], fn ->
          second
          |> fill_in("Name", with: "Renamed by the second")
          |> click_button("Save")
          |> assert_has("*", text: AshQuick.LiveView.ActionErrors.stale_message())
        end)

      assert log =~
               "form save on Example.Catalog.Brand.update refused: " <>
                 "the record changed since it was loaded"

      refute log =~ "Renamed by the"
      refute log =~ brand.name
    end

    # The leak this guards against was a `:warning`, which the suite's own
    # level lets through — so the submitted value is refuted here too, not
    # only the new line.
    test "says nothing at the test suite's own level", %{conn: conn, admin: admin} do
      code = "#{System.unique_integer([:positive])}-not-digits"

      log =
        capture_log(fn ->
          conn
          |> log_in(admin)
          |> visit(~p"/test/digits_only/create")
          |> fill_in("Code", with: code)
          |> click_button("Save")
          |> assert_has(".text-error", text: "is required")
        end)

      refute log =~ "form save on"
      refute log =~ code
    end
  end

  # Raised for the form's own module rather than globally: `config/test.exs`
  # holds the suite at `:warning`, and this module is `async`, so a global
  # `:debug` would pour every concurrent test's debug output — LiveView's own
  # event log, which carries the params — into the captures of tests beside it.
  defp log_saves_at_debug do
    Logger.put_module_level(AshQuick.LiveView.FormUtils, :debug)
    on_exit(fn -> Logger.delete_module_level(AshQuick.LiveView.FormUtils) end)
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
