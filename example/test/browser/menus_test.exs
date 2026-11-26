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
  toward the line's start, which in Arabic is the right, and must stay inside
  the part of the page that shows it either way: the window, and the list's
  card, which cuts off what runs past it. On a phone the list's Export,
  Actions and Filter sit at the line's start, so the first of them grows
  toward its end instead, and a box with too little room beside its button
  slides back into view.
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
    # The left and right of each open menu's box, and of the part of the
    # page that shows it: the window, narrowed by every ancestor that clips
    # what overflows it, such as the list's card.
    defp box(conn, menu) do
      read(conn, """
      (() => {
        const content = document.getElementById("#{menu}-content")
        const box = content.getBoundingClientRect()
        let start = 0, end = window.innerWidth
        for (let node = content.parentElement; node; node = node.parentElement) {
          if (getComputedStyle(node).overflowX === "visible") continue
          const clip = node.getBoundingClientRect()
          start = Math.max(start, clip.left)
          end = Math.min(end, clip.right)
        }
        return {menu: "#{menu}", left: box.left, right: box.right, start, end}
      })()
      """)
    end

    defp assert_on_screen(
           %{"left" => left, "right" => right, "start" => start, "end" => stop} = box
         ) do
      assert left >= start, inspect(box)
      assert right <= stop, inspect(box)
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

    @tag browser_context_opts: [viewport: %{width: 390, height: 844}]
    test "on a phone, Export, Actions and Filter open inside the window", ctx do
      %{conn: conn, admin: admin, product: product} = ctx

      conn =
        conn
        |> open_list(admin)
        |> click("#select_row_#{product.id}")
        |> assert_has("#bulk-actions-menu")

      for menu <- ["export-menu", "bulk-actions-menu", "filters-menu"] do
        conn
        |> click(trigger(menu))
        |> assert_open(menu)
        |> box(menu)
        |> assert_on_screen()
      end
    end

    # A button narrower than its box leaves less room on the side the box
    # grows toward than the box needs: a label's width hangs on the language
    # and the font. Actions, between Export and Filter, is narrowed here, so
    # its box runs past the card's start, in English its left and in Arabic
    # its right, unless it slides back.
    @tag browser_context_opts: [viewport: %{width: 390, height: 844}]
    test "on a phone, a box wider than the room beside its button slides into view", ctx do
      %{conn: conn, admin: admin, product: product} = ctx

      conn =
        conn
        |> open_list(admin)
        |> click("#select_row_#{product.id}")
        |> assert_has("#bulk-actions-menu")

      read(conn, ~s|document.getElementById("bulk-actions-menu-trigger").style.width = "40px"|)

      conn
      |> click(trigger("bulk-actions-menu"))
      |> assert_open("bulk-actions-menu")
      |> box("bulk-actions-menu")
      |> assert_on_screen()
    end

    # A list with no Export, where Filter comes first: the example always
    # offers Export, so the page drops it.
    @tag browser_context_opts: [viewport: %{width: 390, height: 844}]
    test "on a phone, the first menu opens inside the window", ctx do
      %{conn: conn, admin: admin} = ctx
      conn = open_list(conn, admin)
      read(conn, ~s|document.getElementById("export-menu").remove()|)

      conn
      |> click(trigger("filters-menu"))
      |> assert_open("filters-menu")
      |> box("filters-menu")
      |> assert_on_screen()
    end
  end
end
