defmodule ExampleWeb.Browser.FilterPickersTest do
  @moduledoc """
  The picker a filter row picks its values with, in a real browser: a
  relationship's records for Any Of (`/test/brand_record_filter`) and a fixed
  set of values for Has Any Of (the products page). Each runs in English and
  in Arabic, right to left, as a reader whose language that is.
  """
  use ExampleWeb.BrowserCase,
    parameterize: [%{locale: :en}, %{locale: :ar}]

  @picker "[data-aq-picker][id^='filter-values-']"
  @input "#{@picker} [data-part=input]"

  setup %{locale: locale} do
    %{admin: admin} = roles()
    admin = Ash.update!(admin, %{locale: locale}, authorize?: false)
    prefix = "F#{System.unique_integer([:positive])}"

    [northwind, northgate, southgate] =
      for name <- ~w(Northwind Northgate Southgate),
          do: brand(name: "#{prefix} #{name}", actor: admin)

    %{
      admin: admin,
      prefix: prefix,
      products: %{
        northwind: product(brand: northwind, tags: [:sale], actor: admin),
        northgate: product(brand: northgate, tags: [:new], actor: admin),
        southgate: product(brand: southgate, tags: [:clearance, :sale], actor: admin)
      }
    }
  end

  # Sets the filter's only row to the field `value` names, by its label in
  # the page's language.
  defp filter_by(conn, value) do
    field = read(conn, "document.querySelector('select[name^=field_name]').ariaLabel")

    option =
      read(
        conn,
        "document.querySelector('select[name^=field_name] option[value=\"#{value}\"]').textContent.trim()"
      )

    conn
    |> select(field, option: option)
    |> assert_has(@picker)
  end

  defp apply_filters(conn) do
    button =
      read(conn, "document.querySelector('#custom-filter-form [type=submit]').textContent.trim()")

    click_button(conn, button)
  end

  test "Any Of picks a relationship's records by search, keyboard and mouse, and keeps the rows holding them",
       %{conn: conn, admin: admin, prefix: prefix, products: products} do
    conn
    |> log_in(admin)
    |> visit("/test/brand_record_filter?show_custom_filter=true")
    |> connected()
    |> filter_by("brand")
    |> click(@input)
    |> assert_has("#{@picker} [role=option]", count: 3)
    |> type(@input, "#{prefix} North")
    |> assert_has("#{@picker} [role=option]", count: 2)
    |> press(@input, "Enter")
    |> assert_has("#{@picker} [data-part=tag]", count: 1)
    |> assert_has("#{@picker} [data-part=tag]", text: "Northgate")
    # The list stays open on every brand again, the pick ticked.
    |> assert_has("#{@picker} [role=option]", count: 3)
    |> assert_has("#{@picker} [role=option][aria-selected=true]", count: 1)
    |> click("#{@picker} [role=option]", "#{prefix} Northwind")
    |> assert_has("#{@picker} [data-part=tag]", count: 2)
    |> press(@input, "Escape")
    |> apply_filters()
    |> refute_has("#custom-filter-form")
    |> assert_has("td", text: products.northwind.sku)
    |> assert_has("td", text: products.northgate.sku)
    |> refute_has("td", text: products.southgate.sku)
  end

  test "a reopened filter holds its picks, and a tag's ✕ takes one off",
       %{conn: conn, admin: admin, prefix: prefix, products: products} do
    conn =
      conn
      |> log_in(admin)
      |> visit("/test/brand_record_filter?show_custom_filter=true")
      |> connected()
      |> filter_by("brand")
      |> click(@input)
      |> assert_has("#{@picker} [role=option]", count: 3)
      |> type(@input, "#{prefix} Northg")
      |> assert_has("#{@picker} [role=option]", count: 1)
      |> press(@input, "Enter")
      |> assert_has("#{@picker} [data-part=tag]", count: 1)
      |> assert_has("#{@picker} [role=option]", count: 3)
      |> type(@input, "#{prefix} South")
      |> assert_has("#{@picker} [role=option]", count: 1)
      |> press(@input, "Enter")
      |> assert_has("#{@picker} [data-part=tag]", count: 2)
      |> press(@input, "Escape")
      |> apply_filters()
      |> refute_has("td", text: products.northwind.sku)
      |> assert_has("td", text: products.southgate.sku)

    # Open the filter again from the URL the list now carries.
    url = read(conn, "location.pathname + location.search")

    conn
    |> visit(url <> "&show_custom_filter=true")
    |> connected()
    |> assert_has("#{@picker} [data-part=tag]", count: 2)
    |> click("#{@picker} [data-part=tag]:has-text('Northgate') button")
    |> assert_has("#{@picker} [data-part=tag]", count: 1)
    |> apply_filters()
    |> refute_has("td", text: products.northgate.sku)
    |> assert_has("td", text: products.southgate.sku)
  end

  test "Has Any Of picks from a fixed set of values",
       %{conn: conn, admin: admin, products: products} do
    conn
    |> log_in(admin)
    |> visit("/products?show_custom_filter=true")
    |> connected()
    |> filter_by("tags")
    |> click(@input)
    |> assert_has("#{@picker} [role=option]", count: 4)
    |> assert_has("#{@input}[aria-activedescendant$='-opt-0']")
    # New, Sale, Clearance, Staff Pick: ArrowDown lands on Sale.
    |> press(@input, "ArrowDown")
    |> press(@input, "Enter")
    |> assert_has("#{@picker} [data-part=tag][data-value=sale]")
    |> press(@input, "Escape")
    |> apply_filters()
    |> assert_has("td", text: products.northwind.sku)
    |> assert_has("td", text: products.southgate.sku)
    |> refute_has("td", text: products.northgate.sku)
  end
end
