defmodule ExampleWeb.TimezoneScenarioTest do
  @moduledoc """
  A timestamp reads in the zone of the reader's scope, on the list, the
  details page and in an export, and a form reads one typed into it in that
  zone too, so what is saved is the instant the reader meant.

  This app fills the scope with the zone the browser reports: it names it in
  the connect params (`in_timezone/2`), and `ExampleWeb.UserAuth` hands it to
  the scope. Tokyo keeps no daylight saving,
  so the offset is nine hours all year. `Example.Test.DatedEntries` holds the
  rows; `ExampleWeb.DatedEntriesScenarioTest` reads the same fields in UTC.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.{DatedEntries, S3Stub, StampedTemplates}

  @export_timeout to_timeout(second: 5)

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  test "the list and the details page show a timestamp in the browser's zone", %{conn: conn} do
    record = dated_entry()
    # A visit after the first starts from a recycled conn, which carries no
    # connect params, so each page is visited from the tab itself.
    tab = in_timezone(conn, "Asia/Tokyo")

    tab
    |> visit(~p"/test/dated_entries?search=#{record.code}")
    |> assert_has("td", text: "Nov 12, 2026, 10:14:15")
    |> refute_has("td", text: "Nov 12, 2026, 1:14:15")

    tab
    |> visit(~p"/test/dated_entries/#{record.id}")
    |> assert_has(~s([data-field="stamped_at"] dd), text: "Nov 12, 2026, 10:14:15")
  end

  # A naive datetime names no zone, so there is nothing to shift.
  test "a naive datetime reads as it was stored", %{conn: conn} do
    record = dated_entry()

    conn
    |> in_timezone("Asia/Tokyo")
    |> visit(~p"/test/dated_entries/#{record.id}")
    |> assert_has(~s([data-field="logged_at"] dd), text: "Mar 4, 2026, 5:06:07")
  end

  test "a zone the server does not know reads as the configured one", %{conn: conn} do
    record = dated_entry()

    conn
    |> in_timezone("Nowhere/Atlantis")
    |> visit(~p"/test/dated_entries/#{record.id}")
    |> assert_has(~s([data-field="stamped_at"] dd), text: "Nov 12, 2026, 1:14:15")
  end

  test "an export writes a timestamp in the browser's zone", %{conn: conn, admin: admin} do
    record = dated_entry()

    {:ok, view, _html} =
      conn |> in_timezone("Asia/Tokyo") |> live(~p"/test/dated_entries?search=#{record.code}")

    view |> element("a", "CSV") |> render_click()
    render_async(view, @export_timeout)

    csv = exported_csv(admin)
    assert csv =~ "Nov 12, 2026, 10:14:15"
    refute csv =~ "Nov 12, 2026, 1:14:15"
  end

  describe "a form" do
    test "shows a held timestamp in the browser's zone", %{conn: conn} do
      record = dated_entry()

      {:ok, view, _html} =
        conn |> in_timezone("Asia/Tokyo") |> live(~p"/test/dated_entries/#{record.id}/update")

      assert input_value(view, "stamped_at") == "2026-11-12T22:14:15"
    end

    # A value with seconds fails the browser's default step of a minute as soon
    # as its seconds are edited, and Save then posts nothing.
    test "takes a value to the second", %{conn: conn} do
      record = dated_entry()

      {:ok, view, _html} =
        conn |> in_timezone("Asia/Tokyo") |> live(~p"/test/dated_entries/#{record.id}/update")

      assert input_attribute(view, "stamped_at", "step") == "1"
    end

    # The input shows the second, so a save of the value it showed would drop
    # the microseconds, and Ash would count the field as changed.
    test "keeps an untouched timestamp to the microsecond", %{conn: conn} do
      record = dated_entry()

      conn
      |> in_timezone("Asia/Tokyo")
      |> visit(~p"/test/dated_entries/#{record.id}/update")
      |> click_button("Save")

      assert Ash.get!(DatedEntries, record.id).stamped_at == ~U[2026-11-12 13:14:15.123456Z]
    end

    test "saves a timestamp typed in the browser's zone as that instant", %{conn: conn} do
      record = dated_entry()

      conn
      |> in_timezone("Asia/Tokyo")
      |> visit(~p"/test/dated_entries/#{record.id}/update")
      |> fill_in("Stamped At", with: "2026-11-13T09:30")
      |> click_button("Save")

      assert Ash.get!(DatedEntries, record.id).stamped_at == ~U[2026-11-13 00:30:00.000000Z]
    end

    # A validate round trip carries the value back as the instant it means, so
    # a second one does not shift it again.
    test "keeps what was typed across a validate", %{conn: conn} do
      {:ok, view, _html} =
        conn |> in_timezone("Asia/Tokyo") |> live(~p"/test/dated_entries/create")

      code = unique("TZ")

      for _round <- 1..2 do
        view
        |> form("#ash-quick-action-modal form",
          form: %{code: code, stamped_at: "2026-11-13T09:30"}
        )
        |> render_change()

        assert input_value(view, "stamped_at") == "2026-11-13T09:30"
      end

      view |> form("#ash-quick-action-modal form") |> render_submit()

      assert [%{stamped_at: ~U[2026-11-13 00:30:00.000000Z]}] =
               DatedEntries |> Ash.Query.filter_input(%{code: code}) |> Ash.read!()
    end
  end

  # A custom template draws the input itself, and the page reads what it posts
  # in the reader's zone, so the template has to show the held value in that
  # zone too, or an untouched field moves by the offset on every save.
  describe "a custom form template" do
    for {action, drawn_by} <- [update: "AshQuick's .input", restamp: "the app's own .input"] do
      test "drawing it with #{drawn_by} saves an untouched timestamp unmoved", %{conn: conn} do
        record =
          Ash.create!(StampedTemplates, %{
            code: unique("ST"),
            stamped_at: ~U[2026-11-12 13:14:15.123456Z]
          })

        {:ok, view, _html} =
          conn
          |> in_timezone("Asia/Tokyo")
          |> live(~p"/test/stamped_templates/#{record.id}/#{unquote(action)}")

        assert input_attribute(view, "stamped_at", "value") == "2026-11-12T22:14:15"
        assert input_attribute(view, "stamped_at", "step") == "1"

        view |> form("#stamped-form") |> render_submit()

        assert Ash.get!(StampedTemplates, record.id).stamped_at ==
                 ~U[2026-11-12 13:14:15.123456Z]
      end
    end
  end

  defp input_value(view, name), do: input_attribute(view, name, "value")

  defp input_attribute(view, name, attribute) do
    [value] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s(input[name="form[#{name}]"]))
      |> LazyHTML.attribute(attribute)

    value
  end

  defp dated_entry do
    Ash.create!(DatedEntries, %{
      code: unique("TZ"),
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
