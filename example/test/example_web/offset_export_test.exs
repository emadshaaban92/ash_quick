defmodule ExampleWeb.OffsetExportTest do
  @moduledoc """
  A list whose action pages by offset alone exports, as it lists.

  Over `Example.Test.OffsetPages`, whose list action has no keyset pagination
  and reads two rows a page, and `Example.Test.WideOffsetPages`, the same with
  room for 250. Their ETS tables are written by this module alone, once, so
  the rows below are the whole tables.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.{OffsetPages, S3Stub, WideOffsetPages}

  # An export is generated in a task that competes with every async case, so
  # `render_async/1`'s 100 ms default is too short; see `ListScenarioTest`.
  @export_timeout to_timeout(second: 5)

  setup_all do
    for resource <- [OffsetPages, WideOffsetPages], n <- 1..5 do
      resource
      |> Ash.Changeset.for_create(:create, %{code: "Offset row #{n}"})
      |> Ash.create!(authorize?: false)
    end

    :ok
  end

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  test "the list pages by offset", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/test/offset_pages?page=2")

    assert html =~ "Showing 3-4 of 5"
    assert has_element?(view, "td", "Offset row 3")
    refute has_element?(view, "td", "Offset row 2")
  end

  for format <- ["CSV", "Excel"] do
    test "a #{format} export holds every row, past the first page", ctx do
      %{conn: conn, admin: admin} = ctx

      {:ok, view, _html} = live(conn, ~p"/test/offset_pages")

      view |> element("a", unquote(format)) |> render_click()
      render_async(view, @export_timeout)

      assert has_element?(view, "#ash-quick-export-modal a", "Download")
      refute has_element?(view, "#ash-quick-export-modal button", "Retry")

      if unquote(format) == "CSV" do
        [_header | rows] = admin |> exported_body() |> String.split("\r\n", trim: true)
        assert rows == Enum.map(1..5, &"Offset row #{&1}")
      end
    end
  end

  # A batch is a read of the list action, a count with it, so an export
  # batched by the page's two rows would read the five rows three times.
  test "an export reads in batches of up to 250 rows, not of a page", ctx do
    %{conn: conn, admin: admin} = ctx
    test_pid = self()
    handler = {__MODULE__, test_pid}
    event = [:ash, Ash.Domain.Info.short_name(Example.Test.OffsetPages.Domain), :read, :start]

    :telemetry.attach(
      handler,
      event,
      fn _event, _measurements, metadata, _config ->
        if metadata.resource == WideOffsetPages and metadata.action == :index,
          do: send(test_pid, :list_read)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, view, _html} = live(conn, ~p"/test/wide_offset_pages")
    flush_list_reads()

    view |> element("a", "CSV") |> render_click()
    render_async(view, @export_timeout)

    [_header | rows] = admin |> exported_body() |> String.split("\r\n", trim: true)
    assert rows == Enum.map(1..5, &"Offset row #{&1}")
    assert flush_list_reads() == 1
  end

  defp flush_list_reads(count \\ 0) do
    receive do
      :list_read -> flush_list_reads(count + 1)
    after
      0 -> count
    end
  end

  # Exports are keyed by the actor, and every test makes its own users, so
  # this finds exactly the file this test's click produced.
  defp exported_body(actor) do
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
