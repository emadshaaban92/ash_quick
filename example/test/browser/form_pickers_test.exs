defmodule ExampleWeb.Browser.FormPickersTest do
  @moduledoc """
  The pickers a QuickView form draws, in a real browser, on the products
  page: a belongs-to picked by keyboard and one by mouse, a list of fixed
  values, and a list of names that adds the ones it does not find. Each test
  saves, and reads back what was saved: a pick is only as good as what the form
  posts with it.
  """
  use ExampleWeb.BrowserCase

  require Ash.Query

  alias Example.Catalog.{Label, Product}

  setup do
    %{admin: admin} = roles()
    prefix = "P#{System.unique_integer([:positive])}"

    %{
      admin: admin,
      prefix: prefix,
      northwind: brand(name: "#{prefix} Northwind", actor: admin),
      northgate: brand(name: "#{prefix} Northgate", actor: admin),
      # So the list a picker opens on is not the one a search for "North"
      # answers: an assertion on that answer waits for it.
      southgate: brand(name: "#{prefix} Southgate", actor: admin),
      tents: category(name: "#{prefix} Tents", actor: admin),
      family: Ash.create!(Label, %{name: "#{prefix} Family"}, actor: admin)
    }
  end

  defp saved(sku) do
    Product
    |> Ash.Query.filter(sku == ^sku)
    |> Ash.Query.load([:brand, :category, :labels])
    |> Ash.read_one!(authorize?: false)
  end

  defp fill_required(conn, sku) do
    conn
    |> fill_in("Sku", with: sku)
    |> fill_in("Name", with: "Four-season tent")
    |> fill_in("#form_price_amount", "Price", with: "199")
  end

  test "a create form picks each relationship and value list, and saves what it picked",
       %{conn: conn, admin: admin, prefix: prefix} = context do
    sku = "#{prefix}-SKU"

    conn
    |> log_in(admin)
    |> visit(~p"/products/create")
    |> connected()
    |> fill_required(sku)
    # Brand, by keyboard: two of the three brands match, ArrowDown lands on
    # the second.
    |> click("#form_brand_id")
    |> assert_has("#form_brand_id-picker-listbox [role=option]", count: 3)
    |> type("#form_brand_id", "#{prefix} North")
    |> assert_has("#form_brand_id-picker-listbox [role=option]", count: 2)
    |> press("#form_brand_id", "ArrowDown")
    |> assert_has("#form_brand_id[aria-activedescendant=form_brand_id-picker-opt-1]")
    |> press("#form_brand_id", "Enter")
    |> assert_has("#form_brand_id-picker [data-part=selection]", text: "Northwind")
    # Category, by mouse.
    |> click("#form_category_id-picker [data-part=box]")
    |> type("#form_category_id", prefix)
    |> click("#form_category_id-picker-listbox [role=option]", "#{prefix} Tents")
    |> assert_has("#form_category_id-picker [data-part=selection]", text: "Tents")
    # Tags, a fixed set of values: two picked from the list it keeps open.
    |> click("#form_tags-picker [data-part=box]")
    |> click("#form_tags-picker-listbox [role=option]", "Sale")
    |> click("#form_tags-picker-listbox [role=option]", "Staff Pick")
    |> assert_has("#form_tags-picker [data-part=tag]", count: 2)
    |> press("#form_tags", "Escape")
    # Labels: one that exists, and one the save creates.
    |> click("#form_labels")
    |> type("#form_labels", "#{prefix} Fam")
    |> click("#form_labels-picker-listbox [role=option]", "#{prefix} Family")
    |> type("#form_labels", "#{prefix} Kayak")
    |> assert_has("#form_labels-picker-opt-add")
    |> press("#form_labels", "Enter")
    |> assert_has("#form_labels-picker [data-part=tag]", count: 2)
    |> assert_has("#form_labels-picker [data-part=tag][data-new]", text: "Kayak")
    |> press("#form_labels", "Escape")
    |> click_button("Save")
    |> refute_has("form[phx-submit=save]")

    product = saved(sku)
    assert product.brand_id == context.northwind.id
    assert product.category_id == context.tents.id
    assert Enum.sort(product.tags) == [:sale, :staff_pick]

    assert product.labels |> Enum.map(&to_string(&1.name)) |> Enum.sort() ==
             ["#{prefix} Family", "#{prefix} Kayak"]
  end

  test "an update form starts from the record's picks, and saves a changed one",
       %{conn: conn, admin: admin, prefix: prefix} = context do
    product =
      product(
        brand: context.northgate,
        category: context.tents,
        tags: [:new],
        actor: admin
      )

    conn
    |> log_in(admin)
    |> visit(~p"/products/#{product.id}/update")
    |> connected()
    |> assert_has("#form_brand_id-picker [data-part=selection]", text: "#{prefix} Northgate")
    |> assert_has("#form_tags-picker [data-part=tag]", count: 1)
    # Typing over a single picker's selection searches; Enter swaps it.
    |> click("#form_brand_id")
    |> type("#form_brand_id", "#{prefix} Northw")
    |> assert_has("#form_brand_id-picker-listbox [role=option]", count: 1)
    |> press("#form_brand_id", "Enter")
    |> assert_has("#form_brand_id-picker [data-part=selection]", text: "Northwind")
    # Backspace in an empty tags box takes the last tag off.
    |> click("#form_tags")
    |> press("#form_tags", "Escape")
    |> press("#form_tags", "Backspace")
    |> refute_has("#form_tags-picker [data-part=tag]")
    |> click_button("Save")
    |> refute_has("form[phx-submit=save]")

    product = saved(product.sku)
    assert product.brand_id == context.northwind.id
    assert product.category_id == context.tents.id
    assert product.tags == []
  end

  test "clearing a required relationship marks its picker invalid, and keeps the record",
       %{conn: conn, admin: admin} = context do
    product = product(brand: context.northgate, category: context.tents, actor: admin)

    conn
    |> log_in(admin)
    |> visit(~p"/products/#{product.id}/update")
    |> connected()
    |> click("#form_brand_id-picker [data-clear]")
    |> refute_has("#form_brand_id-picker [data-part=selection]")
    |> click_button("Save")
    |> assert_has("#form_brand_id[aria-invalid=true]")
    |> assert_has("form[phx-submit=save]")

    assert saved(product.sku).brand_id == context.northgate.id
  end
end
