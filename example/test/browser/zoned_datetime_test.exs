defmodule ExampleWeb.Browser.ZonedDatetimeTest do
  @moduledoc """
  A UTC datetime's input in a real browser
  (`AshQuick.Components.zoned_datetime_input/1`). The reader types a wall time
  and picks a zone beside it, and the `.ZonedDatetime` hook writes the instant
  they mean into the hidden input the form posts: the input itself names no
  zone. It reads a wall time the way the server does, so a time the zone
  skips (a spring-forward gap) is the first instant after it, and one it
  repeats is the earlier.

  The browser here keeps New York's clock, which is the zone the form offers
  first: `assets/js/app.js` sends it in the connect params.
  """
  use ExampleWeb.BrowserCase

  alias Example.Test.DatedEntries

  @moduletag browser_context_opts: [timezone_id: "America/New_York"]

  @local "#form_stamped_at"
  @zone "#form_stamped_at-zone"

  setup do
    %{admin: admin} = roles()
    %{admin: admin}
  end

  defp open_create(conn, admin) do
    conn
    |> log_in(admin)
    |> visit("/test/dated_entries/create")
    |> connected()
  end

  # A wall time typed into the input, as a reader's keys would leave it.
  defp type_time(conn, local), do: fill_in(conn, @local, "Stamped At", with: local)

  # A zone picked from the select. Its labels carry the zone's offset today,
  # so it is picked by value, and the `change` a pick fires is fired too.
  defp pick_zone(conn, zone) do
    tap(conn, fn conn ->
      assert read(conn, """
             (() => {
               const select = document.querySelector("#{@zone}")
               select.value = "#{zone}"
               select.dispatchEvent(new Event("input", {bubbles: true}))
               select.dispatchEvent(new Event("change", {bubbles: true}))
               return select.value
             })()
             """) == zone
    end)
  end

  # What the hidden input posts, as an instant: the hook writes whole
  # seconds, and the server's validate draws it back with microseconds.
  defp instant(conn) do
    {:ok, instant, 0} =
      conn
      |> read("document.querySelector('[name=\"form[stamped_at]\"]').value")
      |> DateTime.from_iso8601()

    DateTime.truncate(instant, :second)
  end

  defp saved(code) do
    DatedEntries
    |> Ash.read!(authorize?: false)
    |> Enum.find(&(&1.code == code))
  end

  test "offers the reader's zone first and posts the instant its wall time means", ctx do
    %{conn: conn, admin: admin} = ctx
    code = unique("Z")

    conn =
      conn
      |> open_create(admin)
      |> fill_in("Code", with: code)
      |> type_time("2026-07-01T09:30:00")

    assert read(conn, "document.querySelector('#{@zone}').value") == "America/New_York"
    assert instant(conn) == ~U[2026-07-01T13:30:00Z]

    conn
    |> click("form button[type=submit]")
    |> assert_has("h1", text: code)

    assert saved(code).stamped_at == ~U[2026-07-01 13:30:00.000000Z]
  end

  test "another zone picked reads the same wall time there", ctx do
    %{conn: conn, admin: admin} = ctx
    code = unique("Z")

    conn =
      conn
      |> open_create(admin)
      |> fill_in("Code", with: code)
      |> type_time("2026-07-01T09:30:00")
      |> pick_zone("Asia/Tokyo")

    assert instant(conn) == ~U[2026-07-01T00:30:00Z]

    conn
    |> click("form button[type=submit]")
    |> assert_has("h1", text: code)

    assert saved(code).stamped_at == ~U[2026-07-01 00:30:00.000000Z]
  end

  test "a wall time the zone skips is the first instant after it, one it repeats the earlier",
       ctx do
    %{conn: conn, admin: admin} = ctx
    conn = open_create(conn, admin)

    # 2:30 on 8 March 2026 never happens in New York: 2:00 EST is 3:00 EDT.
    assert conn |> type_time("2026-03-08T02:30:00") |> instant() == ~U[2026-03-08T07:00:00Z]
    # 1:30 on 1 November 2026 happens twice: first in EDT, then in EST.
    assert conn |> type_time("2026-11-01T01:30:00") |> instant() == ~U[2026-11-01T05:30:00Z]
    # Neither, in a zone that keeps no summer time.
    pick_zone(conn, "Asia/Tokyo")
    assert conn |> type_time("2026-03-08T02:30:00") |> instant() == ~U[2026-03-07T17:30:00Z]
  end
end
