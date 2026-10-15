defmodule ExampleWeb.ActionModalScenarioTest do
  @moduledoc """
  Every action opens in a modal over the page it was opened from — a form for
  one that takes input, a confirmation for one that does not — and closing it,
  or running it, returns there.

  Where it returns is the point. A visitor who opened an action from a searched
  list is back on that list, at that search; one who opened it from a record is
  back on the record. A create moves on, to the record it made, and a delete
  from the record it deleted goes to the list.
  """
  use ExampleWeb.ConnCase, async: true

  require Ash.Query

  alias Example.Catalog.Product

  @modal "#ash-quick-action-modal"

  setup %{admin: admin} do
    brand = brand(name: unique("Northwind "), actor: admin)
    category = category(name: unique("Tents "), actor: admin)
    name = unique("Four-season tent ")

    %{
      brand: brand,
      category: category,
      product: product(name: name, brand: brand, category: category, actor: admin)
    }
  end

  test "an action opened from a searched list runs over it and returns to it", ctx do
    %{conn: conn, admin: admin, product: product} = ctx
    search = product.name

    {:ok, view, _html} = conn |> log_in(admin) |> live(~p"/products?search=#{search}")

    view |> element("##{product.id}-row-actions-dropdown [role=button]") |> render_click()
    view |> element("##{product.id}-action-reprice") |> render_click()

    assert_patch(view, ~p"/products/#{product.id}/reprice?search=#{search}")

    # The list is still there, under the form, and nothing on it can be reached
    # past the modal.
    assert has_element?(view, "#{@modal} form[phx-submit=save]")
    assert has_element?(view, "[inert] tr", product.name)

    view
    |> form("#{@modal} form[phx-submit=save]", %{"form" => %{"price" => "149.00"}})
    |> render_submit()

    assert_patch(view, ~p"/products?search=#{search}")
    refute has_element?(view, @modal)
    refute has_element?(view, "[inert]")
    assert render(view) =~ "Record saved successfully"
    assert has_element?(view, "tr", product.name)

    assert Money.to_string!(Ash.reload!(product, authorize?: false).price) =~ "149"
  end

  test "cancelling an action leaves the record as it was and the list where it was", ctx do
    %{conn: conn, admin: admin, product: product} = ctx
    search = product.name

    {:ok, view, _html} = conn |> log_in(admin) |> live(~p"/products?search=#{search}")

    view |> element("##{product.id}-row-actions-dropdown [role=button]") |> render_click()
    view |> element("##{product.id}-action-update") |> render_click()
    assert_patch(view, ~p"/products/#{product.id}/update?search=#{search}")

    view
    |> form("#{@modal} form[phx-submit=save]", %{"form" => %{"name" => "Never saved"}})
    |> render_change()

    view |> element("#{@modal} a", "Cancel") |> render_click()

    assert_patch(view, ~p"/products?search=#{search}")
    refute has_element?(view, @modal)
    assert has_element?(view, "tr", product.name)
    assert Ash.reload!(product, authorize?: false).name == product.name
  end

  test "an update opened from a record returns to the record", ctx do
    %{conn: conn, admin: admin, product: product} = ctx

    {:ok, view, _html} = conn |> log_in(admin) |> live(~p"/products/#{product.id}")

    view |> element("button", "Update") |> render_click()
    assert_patch(view, ~p"/products/#{product.id}/update")
    assert has_element?(view, "[inert]", "Created by #{admin.name}")

    renamed = unique("Two-person tent ")

    view
    |> form("#{@modal} form[phx-submit=save]", %{"form" => %{"name" => renamed}})
    |> render_submit()

    assert_patch(view, ~p"/products/#{product.id}")
    refute has_element?(view, @modal)
    assert render(view) =~ renamed
  end

  test "a link straight to an action opens it over the record it is for", ctx do
    %{conn: conn, admin: admin, product: product} = ctx

    {:ok, view, _html} = conn |> log_in(admin) |> live(~p"/products/#{product.id}/reprice")

    assert has_element?(view, "#{@modal} form[phx-submit=save]")
    assert has_element?(view, "[inert]", product.name)
    assert has_element?(view, "[inert]", "Created by #{admin.name}")

    view |> element("#{@modal} a[aria-label=Close]") |> render_click()

    assert_patch(view, ~p"/products/#{product.id}")
    refute has_element?(view, @modal)
  end

  test "a create opened from the list goes on to the record it made", ctx do
    %{conn: conn, admin: admin, brand: brand, category: category, product: product} = ctx

    {:ok, view, _html} = conn |> log_in(admin) |> live(~p"/products")

    view |> element("button", "Add Product") |> render_click()
    assert_patch(view, ~p"/products/create")
    assert has_element?(view, "[inert] tr", product.name)

    sku = unique("SKU")

    view
    |> form("#{@modal} form[phx-submit=save]", %{
      "form" => %{"sku" => sku, "name" => unique("Hammock "), "price" => "40.00"}
    })
    |> render_submit(%{"form" => %{"brand_id" => brand.id, "category_id" => category.id}})

    created = Product |> Ash.Query.filter(sku == ^sku) |> Ash.read_one!(authorize?: false)

    assert_patch(view, ~p"/products/#{created.id}")
    refute has_element?(view, @modal)
  end

  test "a link straight to a create opens it over the list", %{conn: conn, admin: admin} = ctx do
    {:ok, view, _html} = conn |> log_in(admin) |> live(~p"/products/create")

    assert has_element?(view, "#{@modal} form[phx-submit=save]")
    assert has_element?(view, "[inert] tr", ctx.product.name)

    view |> element("#{@modal} a[aria-label=Close]") |> render_click()

    assert_patch(view, ~p"/products")
    refute has_element?(view, @modal)
  end

  describe "an action that asks for nothing" do
    test "is confirmed in the modal, and cancelling it changes nothing", ctx do
      %{conn: conn, admin: admin, product: product} = ctx

      {:ok, view, _html} = conn |> log_in(admin) |> live(~p"/products/#{product.id}")

      view |> element("a", "Deactivate") |> render_click()
      assert_patch(view, ~p"/products/#{product.id}/deactivate")

      # What it is about to do and to which record, and nothing to fill in.
      assert has_element?(view, "#{@modal} h3", "Deactivate")
      assert has_element?(view, "#{@modal} p", product.name)
      assert has_element?(view, "#{@modal} p", "Are you sure?")
      refute has_element?(view, "#{@modal} input[name^='form[']")

      view |> element("#{@modal} a", "Cancel") |> render_click()

      assert_patch(view, ~p"/products/#{product.id}")
      refute has_element?(view, @modal)
      assert Ash.reload!(product, authorize?: false).active

      view |> element("a", "Deactivate") |> render_click()
      view |> form("#{@modal} form") |> render_submit()

      assert_patch(view, ~p"/products/#{product.id}")
      refute has_element?(view, @modal)
      refute Ash.reload!(product, authorize?: false).active
    end

    test "opens refused for a role that may not run it, and a forged run is refused", ctx do
      %{conn: conn, viewer: viewer, product: product} = ctx

      {:ok, view, _html} = conn |> log_in(viewer) |> live(~p"/products/#{product.id}")
      refute has_element?(view, "a", "Deactivate")

      # A hidden link stops nobody from pushing the event behind it, which
      # opens the action like its URL would — refused, with nothing to confirm.
      render_click(view, "row_action_click", %{"id" => product.id, "action_name" => "deactivate"})
      assert_patch(view, ~p"/products/#{product.id}/deactivate")

      assert has_element?(view, @modal, "Access Forbidden")
      refute has_element?(view, "#{@modal} form")

      # Nor does pushing the confirmation it withheld run it.
      render_submit(view, "save", %{})

      assert has_element?(view, "#flash-error", "You don't have permission to do that.")
      assert Ash.reload!(product, authorize?: false).active
    end
  end

  describe "a delete" do
    test "from the record it deletes goes to the list", ctx do
      %{conn: conn, admin: admin, product: product} = ctx

      {:ok, view, _html} = conn |> log_in(admin) |> live(~p"/products/#{product.id}")

      view |> element("button", "Delete") |> render_click()
      assert_patch(view, ~p"/products/#{product.id}/destroy")
      assert has_element?(view, "#{@modal} button.btn-error", "Confirm")

      view |> form("#{@modal} form") |> render_submit()

      assert_patch(view, ~p"/products")
      refute has_element?(view, @modal)
      assert render(view) =~ "Record deleted successfully"
      assert {:error, _} = Ash.get(Product, product.id, authorize?: false)
    end

    test "from a searched list stays on it", ctx do
      %{conn: conn, admin: admin, product: product} = ctx
      search = product.name

      {:ok, view, _html} = conn |> log_in(admin) |> live(~p"/products?search=#{search}")

      view |> element("##{product.id}-row-actions-dropdown [role=button]") |> render_click()
      view |> element("##{product.id}-action-destroy") |> render_click()
      assert_patch(view, ~p"/products/#{product.id}/destroy?search=#{search}")

      view |> form("#{@modal} form") |> render_submit()

      assert_patch(view, ~p"/products?search=#{search}")
      refute has_element?(view, "tr", product.name)
      assert {:error, _} = Ash.get(Product, product.id, authorize?: false)
    end

    test "reached by its URL by a role that may not delete is refused there", ctx do
      %{conn: conn, viewer: viewer, product: product} = ctx

      {:ok, view, html} = conn |> log_in(viewer) |> live(~p"/products/#{product.id}/destroy")

      assert html =~ "Forbidden"
      refute has_element?(view, "#{@modal} form")
      assert has_element?(view, "[inert]", product.name)
      assert {:ok, _} = Ash.get(Product, product.id, authorize?: false)
    end
  end
end
