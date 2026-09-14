defmodule ExampleWeb.QuickViewScenarioTest do
  @moduledoc """
  A QuickView driven the way a person drives it, through three roles in turn.

  This is the test the library cannot write for itself: there is no router, no
  endpoint and no session in the package, so nothing there can show that a list
  page renders records, that the generated form saves one, that a row action
  runs, or that a control the policy forbids is simply not on the page.

  Written as one lifecycle rather than a pile of one-shot tests, because the
  handoffs between roles are the part worth covering: an editor creates a
  product, an admin reprices it, and a viewer can see both and change neither.
  """
  use ExampleWeb.ConnCase, async: true

  require Ash.Query

  alias Example.Catalog.Product

  test "a catalog record through create, a row action, and a role that may do neither",
       %{conn: conn, admin: admin, editor: editor, viewer: viewer} do
    brand = brand(name: "Northwind #{unique("")}", actor: admin)
    category = category(name: "Tents #{unique("")}", actor: admin)

    # --- The editor creates a product through the generated form. -----------
    sku = unique("SKU")

    {:ok, view, _html} = conn |> log_in(editor) |> live(~p"/products")

    # The control is there because `Example.Checks.ActorCanWrite` says yes —
    # QuickView renders no button for an action the actor could not run.
    assert has_element?(view, "button", "Add Product")

    view |> element("button", "Add Product") |> render_click()

    # The two relationships are LiveSelect dropdowns, whose hidden input a
    # `form/3` cannot be given a value for — its options are loaded by the
    # component's own `phx-target`, which a LiveView test cannot reach. They are
    # passed at submit instead, which is exactly what the browser sends once the
    # user has picked one.
    view
    |> form("#product-create", %{
      "form" => %{
        "sku" => sku,
        "name" => "Four-season tent",
        "description" => "Holds up in weather.",
        "price" => "199.00"
      }
    })
    |> render_submit(%{"form" => %{"brand_id" => brand.id, "category_id" => category.id}})

    created = by_sku(sku)
    assert created.name == "Four-season tent"
    assert created.version == 1
    assert Money.to_string!(created.price) =~ "199"
    # Stamped by the extension's bookkeeping, not by anything the form sent.
    assert created.created_by_id == editor.id

    # The list shows it, with both relationships rendered by name rather than
    # by uuid.
    {:ok, _view, html} = conn |> log_in(editor) |> live(~p"/products")
    assert html =~ "Four-season tent"
    assert html =~ brand.name
    assert html =~ category.name
    refute html =~ created.brand_id

    # --- The admin reprices it from the details page. -----------------------
    {:ok, view, html} = conn |> log_in(admin) |> live(~p"/products/#{created.id}")

    assert html =~ "Four-season tent"
    # The bookkeeping header, built from the resource's declaration.
    assert html =~ "Created by #{editor.name}"

    # `:reprice` is offered because the resource defines it and the policy
    # allows it — nothing in `ExampleWeb.ProductLive.Quick` mentions it.
    view |> element("a", "Reprice") |> render_click()

    {:ok, reprice_view, html} = conn |> log_in(admin) |> live(~p"/products/#{created.id}/reprice")

    # `accept []` on the action, so the form offers the argument and nothing
    # else — a reprice form is not an edit form.
    assert html =~ "form[price]"
    refute html =~ "form[sku]"

    reprice_view
    |> form("##{created.id}-form", %{"form" => %{"price" => "149.00"}})
    |> render_submit()

    repriced = Ash.get!(Product, created.id, load: [:price_changes], authorize?: false)
    assert Money.to_string!(repriced.price) =~ "149"
    # The optimistic lock bumped, and the action's after-hook wrote the log row.
    assert repriced.version == 2
    assert [%{} = change] = repriced.price_changes
    assert Money.to_string!(change.from_price) =~ "199"
    assert Money.to_string!(change.to_price) =~ "149"

    # --- The viewer can read it and change nothing. -------------------------
    {:ok, _view, html} = conn |> log_in(viewer) |> live(~p"/products")

    assert html =~ "Four-season tent"
    refute html =~ "Add Product"

    {:ok, view, html} = conn |> log_in(viewer) |> live(~p"/products/#{created.id}")

    # Asserted against the controls rather than the text: "Updated At" is a
    # field label on this very page, so a bare `refute html =~ "Update"` would
    # pass for the wrong reason on any page that renders one.
    assert html =~ "Four-season tent"
    refute has_element?(view, "a", "Reprice")
    refute has_element?(view, "button", "Update")
    refute has_element?(view, "button", "Delete")

    # Reaching past the missing control fails too: the page is served and says
    # so, with no form on it to submit.
    {:ok, view, html} = conn |> log_in(viewer) |> live(~p"/products/#{created.id}/reprice")

    assert html =~ "Forbidden"
    refute has_element?(view, "form")

    # And a route the role does not hold at all is a 403 rather than an empty
    # page, however they arrive at it.
    assert_raise ExampleWeb.NotAllowedError, fn ->
      conn |> log_in(viewer) |> live(~p"/users")
    end

    unchanged = Ash.get!(Product, created.id, authorize?: false)
    assert Money.to_string!(unchanged.price) =~ "149"

    # --- Every one of those writes is in the audit trail. -------------------
    {:ok, _view, html} = conn |> log_in(admin) |> live(~p"/audit_logs")

    # Atoms are humanized on the way to the page, hence "Reprice" and not
    # `:reprice`.
    assert html =~ "Reprice"
    assert html =~ "Product"
    assert html =~ editor.name
    assert html =~ admin.name

    # Which the viewer holds no route to.
    assert_raise ExampleWeb.NotAllowedError, fn ->
      conn |> log_in(viewer) |> live(~p"/audit_logs")
    end
  end

  defp by_sku(sku) do
    Product
    |> Ash.Query.filter(sku == ^sku)
    |> Ash.read_one!(authorize?: false)
  end
end
