defmodule ExampleWeb.TimezoneScenarioTest do
  @moduledoc """
  A timestamp reads in the zone of the reader's scope: on the list, the
  details page, in an export and in the filter. A form's timestamp is typed
  in a zone picked beside it, the reader's to begin with, and posts as the
  instant it means.

  This app fills the scope with the zone the browser reports: it names it in
  the connect params (`in_timezone/2`), and `ExampleWeb.UserAuth` hands it to
  the scope. Tokyo keeps no daylight saving, so the offset is nine hours all
  year. `Example.Test.DatedEntries` holds the rows; the same fields read in UTC
  in `ExampleWeb.DatedEntriesScenarioTest`.

  The browser composes the time and the zone into the instant it posts, which
  LiveViewTest cannot run: a post here names that instant itself, and the
  composing is pinned in a browser.
  """
  use ExampleWeb.FeatureCase, async: true

  alias AshQuick.LiveView.CustomFilter
  alias Example.Test.{DatedEntries, FilterFields, S3Stub}

  @export_timeout to_timeout(second: 5)
  @stored ~U[2026-11-12 13:14:15.123456Z]

  setup %{conn: conn, admin: admin} do
    {:ok, conn: conn |> log_in(admin) |> in_timezone("Asia/Tokyo")}
  end

  describe "reading" do
    test "the list and the details page show a timestamp in the reader's zone", %{conn: conn} do
      record = dated_entry()

      conn
      |> visit(~p"/test/dated_entries?search=#{record.code}")
      |> assert_has("td", text: "Nov 12, 2026, 10:14:15")

      # A second `visit/2` recycles the conn, which drops its connect params.
      conn
      |> visit(~p"/test/dated_entries/#{record.id}")
      |> assert_has("*", text: "Nov 12, 2026, 10:14:15")
    end

    # A naive datetime names no zone, so there is nothing to shift.
    test "a naive datetime reads as it is", %{conn: conn} do
      record = dated_entry()

      conn
      |> visit(~p"/test/dated_entries?search=#{record.code}")
      |> assert_has("td", text: "Mar 4, 2026, 5:06:07")
    end

    test "a zone the time zone database does not know reads as the configured one", %{
      conn: conn
    } do
      record = dated_entry()

      conn
      |> in_timezone("Mars/Olympus")
      |> visit(~p"/test/dated_entries?search=#{record.code}")
      |> assert_has("td", text: "Nov 12, 2026, 1:14:15")
    end

    test "an export writes a timestamp in the reader's zone", %{conn: conn, admin: admin} do
      record = dated_entry()

      {:ok, view, _html} = live(conn, ~p"/test/dated_entries?search=#{record.code}")
      view |> element("a", "CSV") |> render_click()
      render_async(view, @export_timeout)

      csv = exported_csv(admin)
      assert csv =~ "Nov 12, 2026, 10:14:15"
      refute csv =~ "1:14:15"
    end
  end

  describe "a form" do
    test "shows the held timestamp in the reader's zone, beside that zone", %{conn: conn} do
      record = dated_entry()
      {:ok, view, _html} = live(conn, ~p"/test/dated_entries/#{record.id}/update")

      assert attribute(view, "[data-local]", "value") == "2026-11-12T22:14:15"
      assert attribute(view, "[data-local]", "step") == "1"
      assert attribute(view, "[data-zone] option[selected]", "value") == "Asia/Tokyo"
      assert attribute(view, "[data-instant]", "value") == "2026-11-12T13:14:15.123456Z"
    end

    # This app allows every zone (`timezones: :all`), and the server says
    # which: one per clock the world keeps, not every name the browser knows.
    test "offers a zone per clock, by its offset and the places that keep it", %{conn: conn} do
      record = dated_entry()
      {:ok, view, _html} = live(conn, ~p"/test/dated_entries/#{record.id}/update")

      html = render(view)
      assert html =~ "(UTC+09:00) Tokyo, Seoul, Yakutsk"
      assert html =~ "Berlin, Paris, Madrid"
      refute html =~ ~s(value="Europe/Paris")
    end

    # The hidden input holds the stored instant to the microsecond, so a save
    # that leaves the field alone writes back exactly what was there.
    test "saves an untouched timestamp unmoved, to the microsecond", %{conn: conn} do
      record = dated_entry()
      {:ok, view, _html} = live(conn, ~p"/test/dated_entries/#{record.id}/update")

      view |> form("form[phx-submit=save]") |> render_submit()

      assert Ash.get!(DatedEntries, record.id).stamped_at == @stored
    end

    test "saves the instant the time and the zone mean", %{conn: conn} do
      record = dated_entry()
      {:ok, view, _html} = live(conn, ~p"/test/dated_entries/#{record.id}/update")

      # The browser composes the instant from the time and the zone picked;
      # LiveViewTest runs no hook, so the test posts what it would.
      view
      |> form("form[phx-submit=save]")
      |> render_submit(%{
        "form" => %{
          "stamped_at" => "2026-11-13T08:30:00Z",
          "stamped_at__local" => "2026-11-13T09:30",
          "stamped_at__zone" => "Europe/Berlin"
        }
      })

      assert Ash.get!(DatedEntries, record.id).stamped_at == ~U[2026-11-13 08:30:00.000000Z]
    end

    # The time beside the picker reads in the zone picked, and the picker
    # keeps it, across the re-render a change brings.
    test "shows the time in the zone picked across a re-render", %{conn: conn} do
      record = dated_entry()
      {:ok, view, _html} = live(conn, ~p"/test/dated_entries/#{record.id}/update")

      view
      |> form("form[phx-submit=save]")
      |> render_change(%{
        "_target" => ["form", "stamped_at__zone"],
        "form" => %{
          "stamped_at" => "2026-11-12T13:14:15.123456Z",
          "stamped_at__zone" => "America/New_York"
        }
      })

      assert attribute(view, "[data-local]", "value") == "2026-11-12T08:14:15"
      assert attribute(view, "[data-zone] option[selected]", "value") == "America/New_York"
    end
  end

  describe "the filter" do
    test "reads a timestamp typed in the reader's zone", %{conn: conn} do
      code = unique("TZ")
      later = filter_field(code: "#{code}-later", stamped_at: ~U[2026-10-22 11:00:00.000000Z])
      earlier = filter_field(code: "#{code}-earlier", stamped_at: ~U[2026-10-22 09:00:00.000000Z])

      # 19:00 in Tokyo is 10:00 UTC.
      view = apply_filter(conn, "stamped_at", "gt", "2026-10-22T19:00")

      cells = texts(view, "td")
      assert later.code in cells
      refute earlier.code in cells

      %{custom_filter: filter} = :sys.get_state(view.pid).socket.assigns.params
      assert [%CustomFilter{value: "2026-10-22T10:00:00Z"}] = filter.children

      view |> element("a[title='Advanced filters']") |> render_click()
      assert attribute(view, "input[type='datetime-local']", "value") == "2026-10-22T19:00"
    end

    # The 22nd in Tokyo runs from 15:00 UTC on the 21st to 15:00 UTC on the
    # 22nd.
    test "reads On Day's date as a day in the reader's zone", %{conn: conn} do
      code = unique("TD")
      before = filter_field(code: "#{code}-before", stamped_at: ~U[2026-10-21 14:59:59.999999Z])
      first = filter_field(code: "#{code}-first", stamped_at: ~U[2026-10-21 15:00:00.000000Z])
      last = filter_field(code: "#{code}-last", stamped_at: ~U[2026-10-22 14:59:59.999999Z])
      next = filter_field(code: "#{code}-next", stamped_at: ~U[2026-10-22 15:00:00.000000Z])

      view = apply_filter(conn, "stamped_at", "on", "2026-10-22")

      cells = texts(view, "td")
      assert first.code in cells
      assert last.code in cells
      refute before.code in cells
      refute next.code in cells
    end
  end

  defp dated_entry do
    Ash.create!(DatedEntries, %{
      code: unique("D"),
      due_on: ~D[2026-10-19],
      opens_at: ~T[08:15:30],
      logged_at: ~N[2026-03-04 05:06:07],
      stamped_at: @stored
    })
  end

  defp filter_field(attrs), do: Ash.create!(FilterFields, Map.new(attrs), authorize?: false)

  defp apply_filter(conn, field, operator, value) do
    {:ok, view, _html} = live(conn, "/test/filter_fields?show_custom_filter=true")
    [uuid] = view |> render() |> uuids()

    for {name, input} <- [{"field_name", field}, {"operator", operator}, {"value", value}] do
      view
      |> element("#custom-filter-form")
      |> render_change(%{"_target" => ["#{name}-#{uuid}"], "#{name}-#{uuid}" => input})
    end

    view |> element("#custom-filter-form") |> render_submit()
    view
  end

  defp uuids(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#custom-filter-form select[name^='field_name-']")
    |> LazyHTML.attribute("name")
    |> Enum.map(&String.replace_prefix(&1, "field_name-", ""))
  end

  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp attribute(view, selector, name) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
    |> List.first()
  end

  # Exports are keyed by the actor, and every test makes its own users, so
  # this finds exactly the file this test's click produced.
  defp exported_csv(actor) do
    prefix = "exports/#{actor.id}/"

    assert body =
             Enum.find_value(1..40, fn _attempt ->
               case Enum.find(S3Stub.keys(), &String.contains?(&1, prefix)) do
                 nil ->
                   Process.sleep(25)
                   nil

                 key ->
                   S3Stub.body(key)
               end
             end),
           "nothing was uploaded under #{prefix}"

    body
  end
end
