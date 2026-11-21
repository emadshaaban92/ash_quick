defmodule ExampleWeb.PickerScenarioTest do
  @moduledoc """
  `AshQuick.LiveView.Picker` on its test page (`Example.Test.PickerLive`),
  driven through its own events by `ExampleWeb.PickerDriver`: what it offers,
  what it posts, how it treats values it has no option for, and what it tells
  a screen reader.

  The page's form keeps whatever it was posted, so `#posted` and `#target`
  are what a form handler would read.
  """
  use ExampleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ExampleWeb.PickerDriver, as: Picker

  defp posted(view), do: view |> element("#posted") |> render() |> text_of()
  defp target(view), do: view |> element("#target") |> render() |> text_of()

  # The search tasks the LiveView started that are still running.
  defp searches_running(view) do
    {:links, links} = Process.info(view.pid, :links)

    Enum.count(links, fn pid ->
      case is_pid(pid) && Process.info(pid, :current_stacktrace) do
        {:current_stacktrace, stack} ->
          Enum.any?(stack, &match?({Example.Test.PickerLive, _fun, _arity, _loc}, &1))

        _gone ->
          false
      end
    end)
  end

  # A pick the hook asks for, its post not yet sent; returns the change count
  # the picker replied with.
  defp ask_pick(view, id, value) do
    view |> with_target("##{id}") |> render_hook("pick", %{"value" => value})
    assert_reply(view, %{changed: true, changes: changes})
    changes
  end

  # The hook's post of the stops the page drew for change `changes`, then its
  # word that it posted.
  defp post_stops(view, values, changes) do
    view
    |> element("#picker-form")
    |> render_change(%{"_target" => ["trip", "stops"], "trip" => %{"stops" => values}})

    view |> with_target("#stops-picker") |> render_hook("posted", %{"changes" => changes})
  end

  # The values of the stops picker's hidden inputs.
  defp stops(view) do
    for {"trip[stops][]", value} <- Picker.posted(view, "stops-picker"), do: value
  end

  defp text_of(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()

  defp attr(view, selector, name),
    do:
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute(name)

  describe "a single picker" do
    test "offers the search's options and posts the one picked", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker")

      assert Picker.search(view, "city-picker", "giz") == ["Giza"]
      Picker.pick(view, "city-picker", "Giza")

      assert Picker.picked(view, "city-picker") == ["Giza"]
      assert Picker.posted(view, "city-picker") == [{"trip[city]", "gzh"}]
      assert posted(view) =~ ~s("city" => "gzh")
      assert target(view) == ~s(["trip", "city"])
    end

    test "a pick replaces the one held", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker?trip[city]=cai")

      Picker.search(view, "city-picker", "lux")
      Picker.pick(view, "city-picker", "Luxor")

      assert Picker.picked(view, "city-picker") == ["Luxor"]
      assert Picker.posted(view, "city-picker") == [{"trip[city]", "lux"}]
    end

    test "its ✕ posts the field blank, with the field as the change's target",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker?trip[city]=cai")
      assert Picker.picked(view, "city-picker") == ["Cairo"]

      Picker.clear(view, "city-picker")

      assert Picker.picked(view, "city-picker") == []
      assert Picker.posted(view, "city-picker") == [{"trip[city]", ""}]
      assert posted(view) =~ ~s("city" => "")
      assert target(view) == ~s(["trip", "city"])
      refute has_element?(view, "#city-picker [data-clear]")
    end

    test "two options sharing a label are told apart by value", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker")

      assert Picker.search(view, "city-picker", "alex") == ["Alexandria", "Alexandria"]
      Picker.pick(view, "city-picker", value: "alx_us")

      assert Picker.posted(view, "city-picker") == [{"trip[city]", "alx_us"}]
      Picker.search(view, "city-picker", "alex")

      assert attr(view, "#city-picker-listbox [data-value=alx_us]", "aria-selected") == ["true"]
      assert attr(view, "#city-picker-listbox [data-value=alx_eg]", "aria-selected") == ["false"]
    end
  end

  describe "a tags picker" do
    test "posts each pick, and toggles one picked again off", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker")

      Picker.search(view, "stops-picker", "a")
      Picker.pick(view, "stops-picker", "Cairo")
      Picker.search(view, "stops-picker", "lux")
      Picker.pick(view, "stops-picker", "Luxor")

      assert Picker.picked(view, "stops-picker") == ["Cairo", "Luxor"]

      assert Picker.posted(view, "stops-picker") == [
               {"trip[stops][]", "cai"},
               {"trip[stops][]", "lux"}
             ]

      assert posted(view) =~ ~s("stops" => ["cai", "lux"])
      assert target(view) == ~s(["trip", "stops"])

      Picker.search(view, "stops-picker", "cai")
      Picker.pick(view, "stops-picker", "Cairo")
      assert Picker.picked(view, "stops-picker") == ["Luxor"]
    end

    test "removing the last tag posts only the empty-selection marker", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker?trip[stops][]=cai")

      Picker.remove(view, "stops-picker", "Cairo")

      assert Picker.picked(view, "stops-picker") == []
      assert Picker.posted(view, "stops-picker") == [{"trip[stops_empty_selection]", ""}]
      assert target(view) == ~s(["trip", "stops_empty_selection"])
      # `FormParams.put_emptied_selections/1` reads the marker as an empty list.
      assert posted(view) =~ ~s("stops" => [])
    end

    test "a first page that is not all of them says to keep typing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker")

      assert length(Picker.search(view, "stops-picker")) == 5
      assert has_element?(view, "#stops-picker-popup", "Keep typing to narrow the list")

      Picker.search(view, "stops-picker", "giza")
      refute has_element?(view, "#stops-picker-popup", "Keep typing")
    end
  end

  describe "a change waiting to be posted" do
    # A redraw that left before the hook posted the pick (another input's
    # change, a live update) carries the field's old value.
    test "is kept against a redraw carrying the old value", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker?trip[city]=cai")

      Picker.search(view, "city-picker", "lux")
      view |> with_target("#city-picker") |> render_hook("pick", %{"value" => "lux"})
      assert_reply(view, %{changed: true, changes: changes})

      view |> element("#picker-form") |> render_change(%{"trip" => %{"city" => "cai"}})
      assert Picker.posted(view, "city-picker") == [{"trip[city]", "lux"}]

      # The hook's post, then its word that it posted.
      view |> element("#picker-form") |> render_change(%{"_target" => ["trip", "city"]})
      view |> with_target("#city-picker") |> render_hook("posted", %{"changes" => changes})
      assert Picker.posted(view, "city-picker") == [{"trip[city]", "lux"}]
      assert posted(view) =~ ~s("city" => "lux")
    end

    # Picks faster than a round trip: each pick's post and its `posted` reach
    # the server after the next pick, carrying the selection as the page drew
    # it then, without that pick.
    test "is kept while a newer pick waits, through two quick picks", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker")
      Picker.search(view, "stops-picker")

      first = ask_pick(view, "stops-picker", "cai")
      second = ask_pick(view, "stops-picker", "alx_eg")

      post_stops(view, ["cai"], first)
      assert stops(view) == ["cai", "alx_eg"]

      post_stops(view, ["cai", "alx_eg"], second)
      assert stops(view) == ["cai", "alx_eg"]
    end

    test "is kept through a third pick made before the second is posted", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker")
      Picker.search(view, "stops-picker")

      first = ask_pick(view, "stops-picker", "cai")
      second = ask_pick(view, "stops-picker", "alx_eg")
      post_stops(view, ["cai"], first)
      assert stops(view) == ["cai", "alx_eg"]

      third = ask_pick(view, "stops-picker", "gzh")
      assert stops(view) == ["cai", "alx_eg", "gzh"]

      post_stops(view, ["cai", "alx_eg"], second)
      assert stops(view) == ["cai", "alx_eg", "gzh"]

      post_stops(view, ["cai", "alx_eg", "gzh"], third)
      assert stops(view) == ["cai", "alx_eg", "gzh"]
      assert posted(view) =~ ~s("stops" => ["cai", "alx_eg", "gzh"])
    end

    test "once posted, a value set from outside is taken again", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker?trip[city]=cai")

      Picker.search(view, "city-picker", "lux")
      Picker.pick(view, "city-picker", "Luxor")

      view |> element("#picker-form") |> render_change(%{"trip" => %{"city" => "asw"}})
      assert Picker.picked(view, "city-picker") == ["Aswan"]
    end
  end

  describe "values it has no option for" do
    test "are resolved on mount, and an unknown one is kept", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker?trip[stops][]=cai&trip[stops][]=gone")

      assert Picker.picked(view, "stops-picker") == ["Cairo", "Unavailable"]

      assert Picker.posted(view, "stops-picker") == [
               {"trip[stops][]", "cai"},
               {"trip[stops][]", "gone"}
             ]

      assert has_element?(view, "#stops-picker [data-unavailable][data-value=gone]")

      # Kept through a pick, too.
      Picker.search(view, "stops-picker", "lux")
      Picker.pick(view, "stops-picker", "Luxor")

      assert Picker.posted(view, "stops-picker") |> Enum.map(&elem(&1, 1)) == [
               "cai",
               "gone",
               "lux"
             ]
    end

    test "a single value it cannot resolve stays posted", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker?trip[city]=gone")

      assert Picker.picked(view, "city-picker") == ["Unavailable"]
      assert Picker.posted(view, "city-picker") == [{"trip[city]", "gone"}]
    end

    # What a reconnect does: the form is recovered from the hidden inputs, and
    # the picker, mounted afresh, is handed values it has never offered.
    test "are resolved when the form posts them from outside the picker", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker")

      view
      |> element("#picker-form")
      |> render_change(%{"trip" => %{"stops" => ["asw", "gone"], "city" => "lux"}})

      assert Picker.picked(view, "stops-picker") == ["Aswan", "Unavailable"]
      assert Picker.picked(view, "city-picker") == ["Luxor"]
    end
  end

  describe "searching" do
    test "a search a newer one overtook is cancelled, not left running", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker")

      for _ <- 1..5,
          do: view |> with_target("#city-picker") |> render_hook("search", %{"text" => "slowa"})

      assert searches_running(view) == 1
      render_async(view, 1_000)
      assert searches_running(view) == 0
      assert length(Picker.offered(view, "city-picker")) == 9
    end

    test "text that is not a string searches for everything", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker")

      view |> with_target("#city-picker") |> render_hook("search", %{"text" => %{"a" => 1}})
      render_async(view)
      assert length(Picker.offered(view, "city-picker")) == 11
    end

    test "a result a later search overtook is dropped", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker")

      view |> with_target("#city-picker") |> render_hook("search", %{"text" => "slowsuez"})
      assert Picker.search(view, "city-picker", "tanta") == ["Tanta"]

      Process.sleep(400)
      render_async(view)
      assert Picker.offered(view, "city-picker") == ["Tanta"]
    end

    test "says so while it runs, and how many it found", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker")

      view |> with_target("#city-picker") |> render_hook("search", %{"text" => "slowa"})
      assert view |> element("#city-picker-status") |> render() =~ "Searching…"

      render_async(view, 1_000)
      assert view |> element("#city-picker-status") |> render() =~ "9 results"

      Picker.search(view, "city-picker", "nowhere")
      assert view |> element("#city-picker-status") |> render() =~ "No matches"
      assert has_element?(view, "#city-picker-popup", "No matches")
    end
  end

  describe "adding new values" do
    test "with nothing found, the status says the text can be added", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker")

      Picker.search(view, "labels-picker", "Kayak")

      assert view |> element("#labels-picker-status") |> render() |> text_of() ==
               ~s(No matches. You can add "Kayak".)
    end

    test "offers typed text that matches nothing, and posts it as typed", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker")

      assert Picker.search(view, "labels-picker", " Kayak ") == [~s(Add "Kayak")]
      Picker.pick(view, "labels-picker", ~s(Add "Kayak"))

      assert Picker.picked(view, "labels-picker") == ["Kayak"]
      assert has_element?(view, "#labels-picker [data-part=tag][data-new]", "new")
      assert Picker.posted(view, "labels-picker") == [{"trip[labels][]", "Kayak"}]

      Picker.search(view, "labels-picker", "fam")
      Picker.pick(view, "labels-picker", "Family")
      assert Picker.posted(view, "labels-picker") |> Enum.map(&elem(&1, 1)) == ["Kayak", "Family"]
      refute has_element?(view, "#labels-picker [data-part=tag][data-value=Family][data-new]")
    end

    test "is not offered for a value already offered or picked, in any case",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker")

      assert Picker.search(view, "labels-picker", "family") == ["Family"]

      Picker.search(view, "labels-picker", "Kayak")
      Picker.pick(view, "labels-picker", ~s(Add "Kayak"))
      assert Picker.search(view, "labels-picker", "KAYAK") == []
    end

    test "keeps a new value the form recovers as new, not unavailable", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker?trip[labels][]=Kayak&trip[labels][]=Family")

      assert Picker.picked(view, "labels-picker") == ["Kayak", "Family"]
      assert has_element?(view, "#labels-picker [data-value=Kayak][data-new]")
      refute has_element?(view, "#labels-picker [data-unavailable]")
    end

    test "is not offered by a picker that adds nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker")

      assert Picker.search(view, "stops-picker", "Kayak") == []

      view
      |> with_target("#stops-picker")
      |> render_hook("pick", %{"value" => "Kayak", "new" => true})

      assert_reply(view, %{changed: false})
      assert Picker.picked(view, "stops-picker") == []
    end
  end

  describe "for a screen reader" do
    test "the text box is a combobox over a listbox, labelled and described",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker")
      input = "#trip_city"

      assert attr(view, input, "role") == ["combobox"]
      assert attr(view, input, "aria-controls") == ["city-picker-listbox"]
      assert attr(view, input, "aria-autocomplete") == ["list"]
      assert attr(view, input, "aria-expanded") == ["false"]
      assert attr(view, input, "aria-labelledby") == ["city-label"]
      assert attr(view, input, "aria-describedby") == ["trip_city-help"]
      assert attr(view, input, "aria-invalid") == []
      assert attr(view, input, "name") == []
      assert attr(view, "#city-picker-listbox", "role") == ["listbox"]
      assert attr(view, "#city-picker-listbox", "aria-labelledby") == ["city-label"]
      assert attr(view, "#city-picker-status", "role") == ["status"]
      assert attr(view, "#stops-picker-listbox", "aria-multiselectable") == ["true"]
    end

    test "a picked value and an error are read with the box", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker?trip[city]=cai")

      assert attr(view, "#trip_city", "aria-describedby") == [
               "city-picker-selection trip_city-help"
             ]

      Picker.clear(view, "city-picker")
      assert attr(view, "#trip_city", "aria-describedby") == ["trip_city-help city-errors"]
      assert attr(view, "#trip_city", "aria-invalid") == ["true"]
      assert attr(view, "#city-picker [data-part=box]", "class") |> hd() =~ "input-error"
    end

    test "a tag's ✕ is a button named for what it removes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker?trip[stops][]=cai")

      assert attr(view, "#stops-picker [data-part=tag] button", "aria-label") == [
               "Remove Cairo (Egypt)"
             ]

      assert attr(view, "#stops-picker [data-part=tag] button", "type") == ["button"]
    end

    test "tags sharing a label are named apart by their hints", %{conn: conn} do
      {:ok, view, _html} =
        live(
          conn,
          "/test/picker?trip[stops][]=alx_eg&trip[stops][]=alx_us&trip[stops][]=gone" <>
            "&trip[labels][]=Family"
        )

      assert attr(view, "#stops-picker [data-part=tag] button", "aria-label") ==
               [
                 "Remove Alexandria (Egypt)",
                 "Remove Alexandria (Virginia)",
                 "Remove Unavailable (gone)"
               ]

      assert attr(view, "#labels-picker [data-part=tag] button", "aria-label") == [
               "Remove Family"
             ]
    end

    test "in Arabic", %{conn: conn} do
      {:ok, view, html} =
        live(conn, "/test/picker?locale=ar&trip[stops][]=cai&trip[stops][]=gone")

      assert html =~ ~s(dir="rtl")
      assert Picker.picked(view, "stops-picker") == ["القاهرة", "غير متاح"]

      assert attr(view, "#stops-picker [data-part=tag] button", "aria-label") ==
               ["إزالة القاهرة (Egypt)", "إزالة غير متاح (gone)"]

      Picker.search(view, "stops-picker", "أس")
      assert view |> element("#stops-picker-status") |> render() =~ "نتيجتان"
    end
  end

  describe "the markup" do
    test "has no inline handler or style, and the page forbids them", %{conn: conn} do
      conn = get(conn, "/test/picker")
      [policy] = Plug.Conn.get_resp_header(conn, "content-security-policy")
      refute policy =~ "unsafe-inline"

      {:ok, view, _html} = live(conn, "/test/picker?trip[stops][]=cai")
      Picker.search(view, "stops-picker", "a")
      html = view |> element("#stops-picker") |> render()

      refute html =~ ~r/\son[a-z]+=/
      refute html =~ ~r/\sstyle=/
    end

    test "carries what the submit lock finds pickers by", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/picker")

      assert attr(view, "#city-picker", "data-aq-picker") == ["single"]
      assert attr(view, "#stops-picker", "data-aq-picker") == ["tags"]
    end
  end
end
