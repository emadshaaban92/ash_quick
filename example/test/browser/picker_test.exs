defmodule ExampleWeb.Browser.PickerTest do
  @moduledoc """
  `AshQuick.LiveView.Picker` on its own page (`Example.Test.PickerLive`), in a
  real browser: what its hook does with keys, clicks and focus, and what the
  form posts as a result. Each test runs in English and in Arabic, right to
  left.

  `#posted` shows what the form last posted, so it is what each pick is
  checked against: a pick the page drew but never posted is a pick lost.
  """
  use ExampleWeb.BrowserCase,
    parameterize: [%{locale: "en"}, %{locale: "ar"}]

  # The page's text in each locale: a search that finds both Alexandrias,
  # their name, and Luxor's.
  @text %{
    "en" => %{alex: "alex", alexandria: "Alexandria", luxor: "Luxor"},
    "ar" => %{alex: "الإسك", alexandria: "الإسكندرية", luxor: "الأقصر"}
  }

  setup %{conn: conn, locale: locale} do
    query = if locale == "ar", do: "?locale=ar&", else: "?"
    %{conn: conn, text: @text[locale], query: query}
  end

  defp open(conn, query, params \\ "") do
    conn
    |> visit("/test/picker" <> query <> params)
    |> connected()
  end

  defp focused(conn), do: read(conn, "document.activeElement.id")

  # What the form last posted holds `text`. Playwright reads the text as a
  # JSON string, which PhoenixTest.Playwright passes on unescaped, so the
  # quotes `inspect/1` draws are escaped here.
  defp assert_posted(conn, text, selector \\ "#posted"),
    do: assert_has(conn, selector, text: String.replace(text, ~s("), ~s(\\")))

  describe "a single picker" do
    test "searches as it is typed in, and picks with the arrow keys and Enter",
         %{conn: conn, query: query, text: text} do
      conn =
        conn
        |> open(query)
        |> click("#trip_city")
        |> assert_has("#trip_city[aria-expanded=true]")
        |> type("#trip_city", text.alex)
        # Both Alexandrias, the first one active.
        |> assert_has("#city-picker-listbox [role=option]", count: 2)
        |> assert_has("#city-picker-listbox [role=option]", text: text.alexandria, count: 2)
        |> assert_has("#trip_city[aria-activedescendant=city-picker-opt-0]")
        |> press("#trip_city", "ArrowDown")
        |> assert_has("#trip_city[aria-activedescendant=city-picker-opt-1]")
        |> press("#trip_city", "Enter")
        # The second one is the one in Virginia.
        |> assert_posted(~s("city" => "alx_us"))
        |> assert_posted(~s(["trip", "city"]), "#target")
        |> assert_has("#city-picker [data-part=selection][data-value=alx_us]")
        # A single picker closes once it has picked, and keeps the focus.
        |> assert_has("#trip_city[aria-expanded=false]")

      assert focused(conn) == "trip_city"
    end

    test "ArrowUp wraps to the last option, and Home goes back to the first",
         %{conn: conn, query: query, text: text} do
      conn
      |> open(query)
      |> click("#trip_city")
      |> type("#trip_city", text.alex)
      |> assert_has("#city-picker-listbox [role=option]", count: 2)
      |> press("#trip_city", "ArrowUp")
      |> assert_has("#trip_city[aria-activedescendant=city-picker-opt-1]")
      |> press("#trip_city", "Home")
      |> assert_has("#trip_city[aria-activedescendant=city-picker-opt-0]")
      |> press("#trip_city", "Enter")
      |> assert_posted(~s("city" => "alx_eg"))
    end

    test "Escape closes the list without picking, and a second Escape empties the text",
         %{conn: conn, query: query, text: text} do
      conn
      |> open(query)
      |> click("#trip_city")
      |> type("#trip_city", text.alex)
      |> assert_has("#city-picker-listbox [role=option]", count: 2)
      |> press("#trip_city", "Escape")
      |> assert_has("#trip_city[aria-expanded=false]")
      |> refute_has("#city-picker [data-part=selection]")
      |> assert_has("#trip_city", value: text.alex)
      |> press("#trip_city", "Escape")
      |> assert_has("#trip_city", value: "")
      # Typing again opens the list again.
      |> type("#trip_city", text.alex)
      |> assert_has("#trip_city[aria-expanded=true]")
      |> assert_has("#city-picker-listbox [role=option]", count: 2)
    end

    test "Tab closes the list and moves on without picking",
         %{conn: conn, query: query} do
      conn =
        conn
        |> open(query)
        |> click("#trip_city")
        |> assert_has("#city-picker-listbox [role=option]", count: 11)
        |> press("#trip_city", "Tab")
        |> assert_has("#trip_city[aria-expanded=false]")
        |> refute_has("#city-picker [data-part=selection]")

      refute focused(conn) == "trip_city"
    end

    test "Clear posts the field blank, and the error it draws is described and flagged",
         %{conn: conn, query: query} do
      conn
      |> open(query, "trip[city]=cai")
      |> assert_has("#city-picker [data-part=selection][data-value=cai]")
      |> click("#city-picker [data-clear]")
      |> assert_posted(~s("city" => ""))
      |> refute_has("#city-picker [data-part=selection]")
      |> assert_has("#trip_city[aria-invalid=true]")
      |> assert_has("#trip_city[aria-describedby='trip_city-help city-errors']")
      |> assert_has("#city-errors")
    end

    test "Enter while a slow search is still out picks from its answer, not the list before it",
         %{conn: conn, query: query, text: text} do
      # A search for text starting "slow" takes 300ms to answer; Enter lands
      # before it does, while the list still shows every city, Cairo first
      # and active.
      conn
      |> open(query)
      |> click("#trip_city")
      |> assert_has("#city-picker-listbox [role=option]", count: 11)
      |> assert_has("#trip_city[aria-activedescendant=city-picker-opt-0]")
      |> type("#trip_city", "slow" <> text.luxor)
      |> press("#trip_city", "Enter")
      |> assert_posted(~s("city" => "lux"))
      |> assert_has("#city-picker [data-part=selection][data-value=lux]", text: text.luxor)
    end
  end

  describe "a tags picker" do
    test "opens with ArrowDown, picks by keyboard and stays open for the next pick",
         %{conn: conn, query: query} do
      conn
      |> open(query)
      |> click("#trip_stops")
      |> press("#trip_stops", "Escape")
      |> press("#trip_stops", "ArrowDown")
      |> assert_has("#trip_stops[aria-expanded=true]")
      # A page of five, and the hint that there is more.
      |> assert_has("#stops-picker-listbox [role=option]", count: 5)
      |> assert_has("#stops-picker-popup p")
      |> press("#trip_stops", "ArrowDown")
      |> assert_has("#trip_stops[aria-activedescendant=stops-picker-opt-1]")
      |> press("#trip_stops", "Enter")
      |> assert_has("#stops-picker [data-part=tag]", count: 1)
      |> assert_has("#stops-picker [data-part=tag][data-value=alx_eg]")
      |> assert_posted(~s("stops" => ["alx_eg"]))
      |> assert_has("#trip_stops[aria-expanded=true]")
      |> assert_has("#stops-picker-listbox [role=option][aria-selected=true]", count: 1)
      |> press("#trip_stops", "End")
      |> assert_has("#trip_stops[aria-activedescendant=stops-picker-opt-4]")
      |> press("#trip_stops", "Enter")
      |> assert_has("#stops-picker [data-part=tag]", count: 2)
      |> assert_posted(~s("stops" => ["alx_eg", "asw"]))
    end

    test "Backspace in the empty text box removes the last tag",
         %{conn: conn, query: query} do
      conn
      |> open(query, "trip[stops][]=cai&trip[stops][]=lux")
      |> assert_has("#stops-picker [data-part=tag]", count: 2)
      |> click("#trip_stops")
      |> press("#trip_stops", "Escape")
      |> press("#trip_stops", "Backspace")
      |> assert_has("#stops-picker [data-part=tag]", count: 1)
      |> assert_has("#stops-picker [data-part=tag][data-value=cai]")
      |> assert_posted(~s("stops" => ["cai"]))
    end

    test "a tag's ✕ removes it, an unavailable one too, and hands the focus back to the text box",
         %{conn: conn, query: query} do
      conn =
        conn
        |> open(query, "trip[stops][]=cai&trip[stops][]=gone")
        # A value no option resolves is kept, and drawn for what it is.
        |> assert_has("#stops-picker [data-part=tag][data-value=gone]")
        |> click("#stops-picker [data-part=tag][data-value=gone] button")
        |> assert_has("#stops-picker [data-part=tag]", count: 1)
        |> assert_posted(~s("stops" => ["cai"]))

      assert focused(conn) == "trip_stops"

      conn
      |> click("#stops-picker [data-part=tag][data-value=cai] button")
      |> refute_has("#stops-picker [data-part=tag]")
      |> assert_posted(~s("stops" => []))
    end

    test "three quick clicks in the open list all post",
         %{conn: conn, query: query} do
      conn
      |> open(query)
      |> click("#stops-picker [data-part=box]")
      |> assert_has("#stops-picker-listbox [role=option]", count: 5)
      |> click("#stops-picker-opt-1")
      |> click("#stops-picker-opt-2")
      |> click("#stops-picker-opt-3")
      |> assert_has("#stops-picker [data-part=tag]", count: 3)
      |> assert_posted(~s("stops" => ["alx_eg", "alx_us", "gzh"]))
    end

    test "a reconnect keeps what was picked, and the picker still works after it",
         %{conn: conn, query: query} do
      conn
      |> open(query, "trip[city]=lux")
      |> click("#stops-picker [data-part=box]")
      |> click("#stops-picker-opt-0")
      |> click("#stops-picker-opt-1")
      |> assert_posted(~s("stops" => ["cai", "alx_eg"]))
      |> press("#trip_stops", "Escape")
      |> evaluate("window.liveSocket.disconnect()")
      |> refute_has("[data-phx-main].phx-connected")
      |> evaluate("window.liveSocket.connect()")
      |> connected()
      |> assert_has("#stops-picker [data-part=tag]", count: 2)
      |> assert_has("#city-picker [data-part=selection][data-value=lux]")
      |> assert_posted(~s("stops" => ["cai", "alx_eg"]))
      |> click("#stops-picker [data-part=tag][data-value=alx_eg] button")
      |> assert_has("#stops-picker [data-part=tag]", count: 1)
      |> assert_posted(~s("stops" => ["cai"]))
    end
  end

  describe "a tags picker that adds values" do
    test "offers the typed text as a new value, and adds it with Enter",
         %{conn: conn, query: query} do
      conn
      |> open(query)
      |> click("#trip_labels")
      |> type("#trip_labels", "Kayak")
      |> assert_has("#labels-picker-opt-add", text: "Kayak")
      |> press("#trip_labels", "Enter")
      |> assert_has("#labels-picker [data-part=tag][data-new]", text: "Kayak")
      |> assert_posted(~s("labels" => ["Kayak"]))
      # The list stays open on everything, so the next pick is a click.
      |> click("#labels-picker-listbox [role=option]", "Family")
      |> assert_has("#labels-picker [data-part=tag]", count: 2)
      |> assert_posted(~s("labels" => ["Kayak", "Family"]))
    end

    test "offers no Add row for text an option or a tag already holds, in any case",
         %{conn: conn, query: query} do
      conn
      |> open(query, "trip[labels][]=Kayak")
      |> click("#trip_labels")
      |> type("#trip_labels", "family")
      |> assert_has("#labels-picker-listbox [role=option]", count: 1)
      |> assert_has("#labels-picker-listbox [role=option]", text: "Family")
      |> refute_has("#labels-picker-opt-add")
      |> press("#trip_labels", "Escape")
      |> press("#trip_labels", "Escape")
      |> type("#trip_labels", "KAYAK")
      |> refute_has("#labels-picker-listbox [role=option]")
      |> refute_has("#labels-picker-opt-add")
    end
  end

  describe "layout" do
    # Edges in CSS pixels, read off the page.
    @geometry """
    (() => {
      const edges = (el) => { const r = el.getBoundingClientRect(); return {left: r.left, right: r.right, top: r.top, bottom: r.bottom} }
      const picker = document.getElementById("stops-picker")
      return {
        dir: getComputedStyle(picker).direction,
        width: document.documentElement.clientWidth,
        box: edges(picker.querySelector("[data-part=box]")),
        popup: edges(picker.querySelector("[data-part=popup]")),
        tags: [...picker.querySelectorAll("[data-part=tag]")].map(edges),
        option: edges(picker.querySelector("[role=option]")),
        label: edges(picker.querySelector("[role=option] [data-part=label]"))
      }
    })()
    """

    defp geometry(conn, query) do
      conn =
        conn
        |> open(query, "trip[stops][]=cai&trip[stops][]=lux")
        |> click("#stops-picker [data-part=box]")
        |> assert_has("#stops-picker-listbox [role=option]", count: 5)

      read(conn, @geometry)
    end

    test "the open list hangs from the box's start edge, and tags run in reading order",
         %{conn: conn, query: query, locale: locale} do
      g = geometry(conn, query)
      [first, second] = g["tags"]

      # Below the box, as wide as it.
      assert g["popup"]["top"] >= g["box"]["bottom"]
      assert_in_delta g["popup"]["left"], g["box"]["left"], 1
      assert_in_delta g["popup"]["right"], g["box"]["right"], 1

      case locale do
        "en" ->
          assert g["dir"] == "ltr"
          assert first["right"] <= second["left"]
          # The tick column comes before the label.
          assert g["label"]["left"] > g["option"]["left"] + 8

        "ar" ->
          assert g["dir"] == "rtl"
          assert first["left"] >= second["right"]
          assert g["label"]["right"] < g["option"]["right"] - 8
      end
    end

    @tag browser_context_opts: [viewport: %{width: 390, height: 844}]
    test "on a phone the box and its open list stay on the screen",
         %{conn: conn, query: query} do
      g = geometry(conn, query)
      assert g["width"] == 390

      for part <- ["box", "popup"] do
        assert g[part]["left"] >= 0, part
        assert g[part]["right"] <= g["width"], part
      end
    end
  end
end
