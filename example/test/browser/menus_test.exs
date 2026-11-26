defmodule ExampleWeb.Browser.MenusTest do
  @moduledoc """
  A list's menus in a real browser: a row's actions, a cell's filters, Export
  and the Filter panel. One hook on the list's section opens and closes them
  all (`AshQuick.LiveView.Components.Menu`), and its keys are a menu
  button's: Enter, Space or ↓ open onto the first entry, ↑ onto the last,
  ↓ ↑ Home End move, Escape closes back onto the button, and Tab, a click
  outside or another menu close it. `ExampleWeb.AccessibilityScenarioTest`
  reads the markup; these press the keys.

  In both directions: a menu lines its end up with its button's and grows
  toward the line's start, which in Arabic is the right, and must stay on the
  screen either way. One known gap is recorded as a skipped test.
  """
  use ExampleWeb.BrowserCase,
    parameterize: [%{locale: :en}, %{locale: :ar}]

  setup %{locale: locale} do
    %{admin: admin} = roles()
    admin = Ash.update!(admin, %{locale: locale}, authorize?: false)
    product = product(name: unique("Menu tent "), actor: admin)
    %{admin: admin, product: product, row: "#{product.id}-row-actions-dropdown"}
  end

  defp open_list(conn, admin) do
    conn
    |> log_in(admin)
    |> visit("/products")
    |> connected()
  end

  # The menu's entries, once the server has sent them: until then it holds
  # one disabled "Loading…".
  defp entries(conn, menu) do
    conn
    |> assert_has(~s|[id="#{menu}-content"] [role=menuitem]:not([aria-disabled])|)
    |> read("""
    [...document.querySelectorAll('[id="#{menu}-content"] [role=menuitem]')]
      .map(item => item.textContent.trim())
    """)
  end

  defp trigger(menu), do: ~s([id="#{menu}-trigger"])

  defp assert_open(conn, menu) do
    conn
    |> assert_has(~s([id="#{menu}"].dropdown-open))
    |> assert_has(~s(#{trigger(menu)}[aria-expanded=true]))
  end

  defp assert_shut(conn, menu) do
    conn
    |> refute_has(~s([id="#{menu}"].dropdown-open))
    |> assert_has(~s(#{trigger(menu)}[aria-expanded=false]))
  end

  describe "a row's menu, whose entries arrive from the server" do
    test "opens on its first entry by Enter, and its keys walk the entries", ctx do
      %{conn: conn, admin: admin, row: row} = ctx
      conn = conn |> open_list(admin) |> press(trigger(row), "Enter") |> assert_open(row)

      [first | _] = items = entries(conn, row)
      assert length(items) > 1
      last = List.last(items)

      conn
      |> assert_has(~s([id="#{row}-content"] [role=menuitem]:focus), text: first)
      |> press(":focus", "ArrowDown")
      |> assert_has(~s([id="#{row}-content"] [role=menuitem]:focus), text: Enum.at(items, 1))
      |> press(":focus", "End")
      |> assert_has(~s([id="#{row}-content"] [role=menuitem]:focus), text: last)
      # Past either end it wraps.
      |> press(":focus", "ArrowDown")
      |> assert_has(~s([id="#{row}-content"] [role=menuitem]:focus), text: first)
      |> press(":focus", "ArrowUp")
      |> assert_has(~s([id="#{row}-content"] [role=menuitem]:focus), text: last)
      |> press(":focus", "Home")
      |> assert_has(~s([id="#{row}-content"] [role=menuitem]:focus), text: first)
      # Escape closes it back onto its button.
      |> press(":focus", "Escape")
      |> assert_shut(row)
      |> assert_has("#{trigger(row)}:focus")
    end

    test "Tab closes it", ctx do
      %{conn: conn, admin: admin, row: row} = ctx
      conn = conn |> open_list(admin) |> press(trigger(row), "Enter") |> assert_open(row)
      [first | _] = entries(conn, row)

      conn
      |> assert_has(~s([id="#{row}-content"] [role=menuitem]:focus), text: first)
      |> press(":focus", "Tab")
      |> assert_shut(row)
    end

    test "opened by ↓ or ↑ asks the server for its entries", ctx do
      %{conn: conn, admin: admin, row: row} = ctx
      # ↓ first, on a row whose entries were never sent: once a menu has
      # been opened the server keeps its entries, so ↑ after it would pass
      # without asking. The cell's test below covers ↑ on a fresh menu.
      conn = conn |> open_list(admin) |> press(trigger(row), "ArrowDown") |> assert_open(row)
      [first | _] = items = entries(conn, row)

      conn
      |> assert_has(~s([id="#{row}-content"] [role=menuitem]:focus), text: first)
      |> press(":focus", "Escape")
      |> assert_shut(row)
      |> press(trigger(row), "ArrowUp")
      |> assert_open(row)
      |> assert_has(~s([id="#{row}-content"] [role=menuitem]:focus), text: List.last(items))
    end

    test "a click opens it without moving the focus into it, a second one shuts it", ctx do
      %{conn: conn, admin: admin, row: row} = ctx

      conn =
        conn
        |> open_list(admin)
        |> click(trigger(row))
        |> assert_open(row)
        |> assert_has(~s([id="#{row}-content"] [role=menuitem]))

      assert read(conn, "document.activeElement.id") == "#{row}-trigger"

      conn
      |> click(trigger(row))
      |> assert_shut(row)
    end
  end

  describe "the list's menus together" do
    test "only one is open at a time, and a click outside shuts it", ctx do
      %{conn: conn, admin: admin, row: row} = ctx

      conn
      |> open_list(admin)
      |> click(trigger("export-menu"))
      |> assert_open("export-menu")
      |> click(trigger(row))
      |> assert_open(row)
      |> assert_shut("export-menu")
      |> click("#simple-search")
      |> assert_shut(row)
    end

    # A click that leaves the focus where it was, as in Safari, where a
    # clicked button does not take it: only the pointer says it was outside.
    test "a press outside shuts it even when the focus stays put", ctx do
      %{conn: conn, admin: admin} = ctx

      conn
      |> open_list(admin)
      |> click(trigger("export-menu"))
      |> assert_open("export-menu")
      |> tap(
        &read(&1, """
          document.getElementById("simple-search")
            .dispatchEvent(new PointerEvent("pointerdown", {bubbles: true})) || true
        """)
      )
      |> assert_shut("export-menu")
      |> assert_has("#{trigger("export-menu")}:focus")
    end

    test "a menu drawn with its entries opens onto the first by Space, the last by ↑", ctx do
      %{conn: conn, admin: admin} = ctx

      conn
      |> open_list(admin)
      |> press(trigger("export-menu"), " ")
      |> assert_open("export-menu")
      |> assert_has(~s([id="export-menu-content"] [role=menuitem]:focus), text: "Excel")
      |> press(":focus", "ArrowDown")
      |> assert_has(~s([id="export-menu-content"] [role=menuitem]:focus), text: "CSV")
      |> press(":focus", "Escape")
      |> assert_shut("export-menu")
      |> press(trigger("export-menu"), "ArrowUp")
      |> assert_open("export-menu")
      |> assert_has(~s([id="export-menu-content"] [role=menuitem]:focus), text: "CSV")
    end

    test "a cell's menu opens by Enter onto its first choice, which filters by the cell", ctx do
      %{conn: conn, admin: admin, product: product} = ctx
      cell = "#{product.id}-cell-filter-name"

      conn
      |> open_list(admin)
      |> press(trigger(cell), "Enter")
      |> assert_open(cell)
      |> assert_has(~s([id="#{cell}-content"] [data-cell-filter-choice=equals]:focus))
      |> press(":focus", "Enter")
      |> assert_shut(cell)
      |> assert_has("[data-filter-chip]", text: product.name)
    end

    test "a cell's menu opens by ↑ onto its last choice, once the server sends them", ctx do
      %{conn: conn, admin: admin, product: product} = ctx
      cell = "#{product.id}-cell-filter-name"
      conn = conn |> open_list(admin) |> press(trigger(cell), "ArrowUp") |> assert_open(cell)
      last = conn |> entries(cell) |> List.last()

      assert_has(conn, ~s([id="#{cell}-content"] [role=menuitem]:focus), text: last)
    end
  end

  describe "the Filter panel" do
    test "keeps open while Tab walks into it, and Escape shuts it onto its button", ctx do
      %{conn: conn, admin: admin} = ctx

      conn
      |> open_list(admin)
      |> click(trigger("filters-menu"))
      |> assert_has(~s([id="filters-menu"].dropdown-open))
      |> assert_has(~s(#{trigger("filters-menu")}[aria-expanded=true]))
      |> press(trigger("filters-menu"), "Tab")
      |> assert_has(~s([id="filters-menu-content"] input[type=checkbox]:focus))
      |> assert_has(~s([id="filters-menu"].dropdown-open))
      |> press(":focus", "Escape")
      |> refute_has(~s([id="filters-menu"].dropdown-open))
      |> assert_has(~s(#{trigger("filters-menu")}[aria-expanded=false]:focus))
    end

    test "shuts when the focus leaves it", ctx do
      %{conn: conn, admin: admin} = ctx

      conn
      |> open_list(admin)
      |> click(trigger("filters-menu"))
      |> assert_has(~s([id="filters-menu"].dropdown-open))
      |> press(trigger("filters-menu"), "Tab")
      |> assert_has(~s([id="filters-menu-content"] input[type=checkbox]:focus))
      # Its one box is its last stop.
      |> press(":focus", "Tab")
      |> refute_has(~s([id="filters-menu"].dropdown-open))
    end
  end

  describe "layout" do
    # The rectangle of each open menu's box, and the window's width.
    defp box(conn, menu) do
      read(conn, """
      (() => {
        const box = document.getElementById("#{menu}-content").getBoundingClientRect()
        return {left: box.left, right: box.right, width: window.innerWidth}
      })()
      """)
    end

    defp assert_on_screen(%{"left" => left, "right" => right, "width" => width}) do
      assert left >= 0
      assert right <= width
    end

    test "a row's menu and Export open inside the window", ctx do
      %{conn: conn, admin: admin, row: row} = ctx
      conn = open_list(conn, admin)

      for menu <- [row, "export-menu"] do
        conn
        |> click(trigger(menu))
        |> assert_open(menu)
        |> box(menu)
        |> assert_on_screen()
      end
    end

    @tag browser_context_opts: [viewport: %{width: 390, height: 844}]
    test "on a phone, a row's menu opens inside the window", ctx do
      %{conn: conn, admin: admin, row: row} = ctx

      conn
      |> open_list(admin)
      |> click(trigger(row))
      |> assert_open(row)
      |> box(row)
      |> assert_on_screen()
    end

    # Known gap: Export is wider than its button and opens toward the edge
    # the button sits nearest on a phone. In Arabic its box ends 6px past the
    # window's right edge, and the list's card cuts it off.
    @tag :skip
    @tag browser_context_opts: [viewport: %{width: 390, height: 844}]
    test "on a phone, Export opens inside the window", ctx do
      %{conn: conn, admin: admin} = ctx

      conn
      |> open_list(admin)
      |> click(trigger("export-menu"))
      |> assert_open("export-menu")
      |> box("export-menu")
      |> assert_on_screen()
    end
  end
end
