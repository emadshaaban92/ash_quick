defmodule ExampleWeb.DatedEntriesScenarioTest do
  @moduledoc """
  A date, a time, a naive datetime and a UTC datetime read on the list and
  the details page the way `AshQuick.Config` formats them, not as the ISO
  8601 a value prints as on its own (`2026-10-19`).

  `Example.Test.DatedEntries` holds the fields, one of each type. Only this
  test writes to its table.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.{DatedEntries, S3Stub}

  # An export is generated in a task that competes with every async case, so
  # `render_async/1`'s 100 ms default is too short; see `ListScenarioTest`.
  @export_timeout to_timeout(second: 5)

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  test "the list and the details page format each date and time", %{conn: conn} do
    record = dated_entry()

    conn
    |> visit(~p"/test/dated_entries")
    |> assert_has("td", text: "Oct 19, 2026", exact: true)
    |> assert_has("td", text: "8:15:30")
    |> assert_has("td", text: "Mar 4, 2026, 5:06:07")
    |> assert_has("td", text: "Nov 12, 2026, 1:14:15")
    |> refute_has("td", text: "2026-10-19")
    |> refute_has("td", text: "08:15:30")
    |> refute_has("td", text: "2026-03-04T05:06:07")
    |> visit(~p"/test/dated_entries/#{record.id}")
    |> assert_has("*", text: "Oct 19, 2026", exact: true)
    |> assert_has("*", text: "8:15:30")
    |> assert_has("*", text: "Mar 4, 2026, 5:06:07")
    |> assert_has("*", text: "Nov 12, 2026, 1:14:15")
    |> refute_has("*", text: "2026-10-19")
    |> refute_has("*", text: "08:15:30")
    |> refute_has("*", text: "2026-03-04T05:06:07")
  end

  test "an export writes each date and time as the page shows it", ctx do
    %{conn: conn, admin: admin} = ctx
    record = dated_entry()

    {:ok, view, _html} = live(conn, ~p"/test/dated_entries?search=#{record.code}")

    view |> element("a", "CSV") |> render_click()
    render_async(view, @export_timeout)

    csv = exported_csv(admin)

    assert csv =~ "Oct 19, 2026"
    assert csv =~ "8:15:30"
    assert csv =~ "Mar 4, 2026, 5:06:07"
    assert csv =~ "Nov 12, 2026, 1:14:15"
    refute csv =~ "2026-10-19"
    refute csv =~ "08:15:30"
    refute csv =~ "2026-03-04T05:06:07"
    refute csv =~ "2026-11-12T13:14:15"
  end

  defp dated_entry do
    Ash.create!(DatedEntries, %{
      code: unique("D"),
      due_on: ~D[2026-10-19],
      opens_at: ~T[08:15:30],
      logged_at: ~N[2026-03-04 05:06:07],
      stamped_at: ~U[2026-11-12 13:14:15.123456Z]
    })
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
