defmodule ExampleWeb.ListScenarioTest do
  @moduledoc """
  Working a list page: search it, page through it, filter it, export it.

  Everything here is a round trip through the URL. A QuickView reads its own
  state back out of the query string on every `handle_params`, and corrects the
  URL to say what the page actually did — so "the page is showing what I asked
  for" and "the URL says what the page is showing" are the same assertion, and
  a link copied out of the address bar reproduces the page.

  `AshQuick.LiveView.URLParamsTest` covers the decoder itself, including
  everything a hostile query string can be. What it cannot cover is whether the
  page acts on what was decoded, which is what is driven here.

  There is no sort control: `sort_by` is a QuickView declaration, not something
  a reader clicks. The ordering it produces is asserted all the same, because it
  is what decides which rows a page of results contains.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.S3Stub

  setup %{admin: admin} do
    brand = brand(name: "Northwind Outfitters", actor: admin)
    category = category(name: "Tents", actor: admin)

    %{brand: brand, category: category}
  end

  describe "search" do
    test "narrows the page to what matched, and says so in the URL", ctx do
      %{conn: conn, admin: admin, brand: brand, category: category} = ctx

      tent = product(name: "Four-season tent", brand: brand, category: category, actor: admin)
      lamp = product(name: "Headlamp", brand: brand, category: category, actor: admin)

      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> assert_has("td", text: tent.name)
      |> assert_has("td", text: lamp.name)
      |> fill_in("Search", with: "tent")
      |> assert_has("td", text: tent.name)
      |> refute_has("td", text: lamp.name)
      # The typing put it there: a reader can copy the address bar and get the
      # same page back.
      |> assert_path(~p"/products", query_params: %{"search" => "tent"})

      # And arriving at that URL cold is the same page, which is the half a
      # round trip needs to be worth anything.
      conn
      |> log_in(admin)
      |> visit(~p"/products?search=tent")
      |> assert_has("td", text: tent.name)
      |> refute_has("td", text: lamp.name)
    end

    test "searches every field the resource's lookup action names", ctx do
      %{conn: conn, admin: admin} = ctx

      product = product(name: "Four-season tent", actor: admin)

      # `Example.Catalog.Preparations.ProductsSearch` matches name *or* sku, and
      # the page passes the term to it without knowing either.
      conn
      |> log_in(admin)
      |> visit(~p"/products?search=#{product.sku}")
      |> assert_has("td", text: product.name)
    end
  end

  describe "pagination" do
    setup %{admin: admin, brand: brand, category: category} do
      # Named so they sort predictably under the action's `name: :asc`.
      products =
        for n <- 1..5 do
          product(
            name: "Tent #{n}",
            brand: brand,
            category: category,
            actor: admin
          )
        end

      %{products: products}
    end

    test "shows a page at a time, and counts the whole result", ctx do
      %{conn: conn, admin: admin} = ctx

      conn
      |> log_in(admin)
      |> visit(~p"/products?limit=2")
      |> assert_has("*", text: "Showing 1-2 of 5")
      |> assert_has("td", text: "Tent 1")
      |> assert_has("td", text: "Tent 2")
      |> refute_has("td", text: "Tent 3")
    end

    test "walks to the next page and back, keeping the page size", ctx do
      %{conn: conn, admin: admin} = ctx

      conn
      |> log_in(admin)
      |> visit(~p"/products?limit=2")
      |> click_link("2")
      |> assert_has("*", text: "Showing 3-4 of 5")
      |> assert_has("td", text: "Tent 3")
      |> refute_has("td", text: "Tent 1")
      # The size the reader asked for rides along, so paging does not silently
      # reset it.
      |> assert_path(~p"/products", query_params: %{"limit" => "2", "page" => "2"})
      |> click_link("[aria-label='Previous page']", "")
      |> assert_has("*", text: "Showing 1-2 of 5")
      |> assert_has("td", text: "Tent 1")
    end

    # KNOWN ISSUE — a page past the last renders an empty table under a footer
    # that claims a row. With five records at `limit=2` the last page is 3;
    # `page=4` and beyond produce no rows at all, while the footer still reads
    # "Showing 5-5 of 5" because `min(offset + 1, count)` clamps the arithmetic
    # and nothing clamps the query.
    #
    # `AshQuick.LiveView.URLParams` clamps a page against a row ceiling, which
    # it can do at decode time, but not against the count — which is only known
    # after the read. So the fix belongs in the list read, not in the decoder.
    # The assertion below is what a QuickView already promises: "nothing in a
    # query string is refused, and the URL is then corrected to say what the
    # page actually did".
    @tag :skip
    test "a page past the end is the last one there is, not an empty table", ctx do
      %{conn: conn, admin: admin} = ctx

      conn
      |> log_in(admin)
      |> visit(~p"/products?limit=2&page=99")
      |> assert_has("*", text: "Showing 5-5 of 5")
      |> assert_has("td", text: "Tent 5")
    end

    test "every page the pager itself offers has the rows its footer claims", ctx do
      %{conn: conn, admin: admin} = ctx

      # The three real pages, which is what a reader can reach by clicking.
      for {page, footer, name} <- [
            {1, "Showing 1-2 of 5", "Tent 1"},
            {2, "Showing 3-4 of 5", "Tent 3"},
            {3, "Showing 5-5 of 5", "Tent 5"}
          ] do
        conn
        |> log_in(admin)
        |> visit(~p"/products?limit=2&page=#{page}")
        |> assert_has("*", text: footer)
        |> assert_has("td", text: name)
      end
    end

    test "the whole result fits on one page when nothing asked otherwise", ctx do
      %{conn: conn, admin: admin} = ctx

      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> assert_has("*", text: "Showing 1-5 of 5")
      # No pager at all: it is drawn only when there is more than one page.
      |> refute_has("[aria-label='Previous page']")
    end
  end

  describe "a saved filter" do
    test "toggles the rows it names, and survives a reload", ctx do
      %{conn: conn, admin: admin, brand: brand, category: category} = ctx

      on_sale =
        product(
          name: "Clearance tent",
          tags: [:sale],
          brand: brand,
          category: category,
          actor: admin
        )

      full_price =
        product(name: "Full price tent", brand: brand, category: category, actor: admin)

      # `filters:` on `ExampleWeb.ProductLive.Quick` — a raw `Ash.Expr`, applied
      # by name.
      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products")
        |> assert_has("td", text: full_price.name)
        |> toggle_filter("On sale")

      session
      |> assert_has("td", text: on_sale.name)
      |> refute_has("td", text: full_price.name)
      |> assert_path(~p"/products", query_params: %{"selected_filters" => "on_sale"})

      # Arriving at the URL the toggle produced is the same page.
      conn
      |> log_in(admin)
      |> visit(~p"/products?selected_filters=on_sale")
      |> assert_has("td", text: on_sale.name)
      |> refute_has("td", text: full_price.name)

      # And toggling it off puts everything back, so the assertion above is
      # about the filter rather than about the other row never rendering.
      session
      |> toggle_filter("On sale")
      |> assert_has("td", text: full_price.name)
    end

    test "a filter the page does not offer is ignored rather than raised", ctx do
      %{conn: conn, admin: admin} = ctx

      product = product(name: "Four-season tent", actor: admin)

      # Nothing in a query string is trusted, and a name no filter answers to
      # narrows nothing.
      conn
      |> log_in(admin)
      |> visit(~p"/products?selected_filters=no_such_filter")
      |> assert_has("td", text: product.name)
    end
  end

  describe "export" do
    test "writes the rows the page is showing, with the columns it is showing", ctx do
      %{conn: conn, admin: admin, brand: brand, category: category} = ctx

      tent = product(name: "Four-season tent", brand: brand, category: category, actor: admin)
      lamp = product(name: "Headlamp", brand: brand, category: category, actor: admin)

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/products")

      view |> element("a", "CSV") |> render_click()
      render_async(view)

      csv = exported_csv(admin)

      # `export_fields` falls back to the list's own fields, so the header is
      # what the table's columns are called — including the relationship paths,
      # rendered by name rather than by id.
      [header | rows] = String.split(csv, "\r\n", trim: true)
      assert header =~ "Sku"
      assert header =~ "Brand"
      refute header =~ "Description"

      assert Enum.any?(rows, &(&1 =~ tent.name and &1 =~ brand.name and &1 =~ category.name))
      assert Enum.any?(rows, &(&1 =~ lamp.name))
      refute csv =~ tent.brand_id
    end

    test "exports what a search narrowed it to, not the whole table", ctx do
      %{conn: conn, admin: admin} = ctx

      tent = product(name: "Four-season tent", actor: admin)
      lamp = product(name: "Headlamp", actor: admin)

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/products?search=tent")

      view |> element("a", "CSV") |> render_click()
      render_async(view)

      csv = exported_csv(admin)

      assert csv =~ tent.name
      refute csv =~ lamp.name
    end

    test "offers the formats the host's dependencies actually support", ctx do
      %{conn: conn, admin: admin} = ctx

      product(name: "Four-season tent", actor: admin)

      # `exceed` and `nimble_csv` are dependencies of the example app, so both
      # formats are offered. `chromic_pdf` deliberately is not, so the print
      # control beside them is absent rather than broken.
      assert AshQuick.Config.exports_enabled?()
      refute AshQuick.Config.print_enabled?()

      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> assert_has("a", text: "CSV")
      |> assert_has("a", text: "Excel")
      |> refute_has("*", text: "Print")
    end
  end

  # Exports are keyed by the actor, and every test makes its own users — so this
  # finds exactly the file this test's click produced.
  defp exported_csv(actor) do
    key = "exports/#{actor.id}/products-"

    assert body =
             Enum.find_value(
               1..40,
               fn _attempt ->
                 case find_export(key) do
                   nil ->
                     Process.sleep(25)
                     nil

                   body ->
                     body
                 end
               end
             ),
           "nothing was uploaded under #{key}"

    body
  end

  defp find_export(prefix) do
    Example.Test.S3Stub
    |> :ets.tab2list()
    |> Enum.find(fn {key, _parts} -> String.contains?(key, prefix) end)
    |> case do
      nil -> nil
      {key, _parts} -> S3Stub.body(key)
    end
  end
end
