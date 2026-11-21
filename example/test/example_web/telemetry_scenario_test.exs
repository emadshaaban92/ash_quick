defmodule ExampleWeb.TelemetryScenarioTest do
  @moduledoc """
  The page events `AshQuick.Telemetry` lists, emitted by real pages: a load,
  a list read, a form's save, a bulk run, a print and an export.

  Prints and bulk runs go through `Example.Test.Printable` at
  `/test/printable`, whose actions print through the suite's renderer double;
  the export through `/products`.

  Not async: a `:telemetry` handler hears every process, so a case running
  beside these would be heard too.
  """
  use ExampleWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Example.Test.Printable
  alias Example.Test.PrintableLive

  @page "/test/printable"
  @modal "#ash-quick-action-modal"
  @bulk "a[phx-click*='bulk_action']"
  @print ~r/^\s*Print\s*$/

  defp attach(events) do
    ref = :telemetry_test.attach_event_handlers(self(), events)
    on_exit(fn -> :telemetry.detach(ref) end)
    ref
  end

  defp printable(name) do
    Printable
    |> Ash.Changeset.for_create(:create, %{code: unique("P"), name: name, active: true})
    |> Ash.create!(authorize?: false)
  end

  defp confirm(view), do: view |> form("#{@modal} form") |> render_submit()

  test "a list page's load and read are timed, with what the list was asked", ctx do
    %{conn: conn, admin: admin} = ctx
    printable(unique("Northwind "))

    ref =
      attach([
        [:ash_quick, :page, :load, :stop],
        [:ash_quick, :list, :read, :stop]
      ])

    {:ok, _view, _html} = conn |> log_in(admin) |> live("#{@page}?search=Northwind")

    assert_received {[:ash_quick, :page, :load, :stop], ^ref, %{duration: _},
                     %{
                       quick_view: PrintableLive.Quick,
                       resource: Printable,
                       page: :list,
                       action: _,
                       scope: %{}
                     }}

    assert_received {[:ash_quick, :list, :read, :stop], ^ref, %{duration: _, rows: rows},
                     %{
                       quick_view: PrintableLive.Quick,
                       resource: Printable,
                       page_number: 1,
                       search?: true,
                       custom_filter?: false
                     }}

    assert rows >= 1
  end

  # A link's filter on a value its type cannot cast is refused by the data
  # layer alone: the read raises, and the list is read once more without it.
  test "a list read that raises with a filter is followed by the read without it", ctx do
    %{conn: conn, admin: admin} = ctx

    ref =
      attach([
        [:ash_quick, :list, :read, :exception],
        [:ash_quick, :list, :read, :stop]
      ])

    filter =
      %{"operator" => "equals", "field_name" => "id", "value" => "not-a-uuid"}
      |> JSON.encode!()
      |> :base64.encode()

    capture_log(fn ->
      {:ok, _view, _html} = conn |> log_in(admin) |> live("/products?custom_filter=#{filter}")
    end)

    assert_received {[:ash_quick, :list, :read, :exception], ^ref, %{duration: _},
                     %{resource: Example.Catalog.Product, custom_filter?: true, kind: :error}}

    assert_received {[:ash_quick, :list, :read, :stop], ^ref, _,
                     %{resource: Example.Catalog.Product, custom_filter?: false}}
  end

  test "a details page's load names it as one", %{conn: conn, admin: admin} do
    record = printable(unique("Globex "))
    ref = attach([[:ash_quick, :page, :load, :stop]])

    {:ok, _view, _html} = conn |> log_in(admin) |> live("#{@page}/#{record.id}")

    assert_received {[:ash_quick, :page, :load, :stop], ^ref, _,
                     %{resource: Printable, page: :details}}
  end

  test "a row action's save and its print are timed", %{conn: conn, admin: admin} do
    record = printable(unique("Initech "))
    {:ok, view, _html} = conn |> log_in(admin) |> live(@page)

    ref =
      attach([
        [:ash_quick, :form, :submit, :stop],
        [:ash_quick, :print, :stop]
      ])

    view |> element("##{record.id}-row-actions-dropdown [data-menu-trigger]") |> render_click()
    view |> element("##{record.id}-action-print") |> render_click()
    confirm(view)

    assert_push_event(view, "ash_quick:pdf", _event)

    assert_received {[:ash_quick, :form, :submit, :stop], ^ref, %{duration: _},
                     %{
                       quick_view: PrintableLive.Quick,
                       resource: Printable,
                       action: :print,
                       type: :update,
                       result: :ok
                     }}

    assert_received {[:ash_quick, :print, :stop], ^ref, %{duration: _},
                     %{resource: Printable, template: Printable.Sheet, records: 1}}
  end

  test "a save the action refuses is reported as an error", %{conn: conn, admin: admin} do
    record = printable(unique("Vandelay "))
    {:ok, view, _html} = conn |> log_in(admin) |> live(@page)

    ref = attach([[:ash_quick, :form, :submit, :stop]])

    view |> element("##{record.id}-row-actions-dropdown [data-menu-trigger]") |> render_click()
    view |> element("##{record.id}-action-rename_and_print") |> render_click()

    view
    |> form("#{@modal} form[phx-submit=save]", %{"form" => %{"name" => ""}})
    |> render_submit()

    assert_received {[:ash_quick, :form, :submit, :stop], ^ref, _,
                     %{action: :rename_and_print, type: :update, result: :error}}
  end

  test "a bulk run is timed, with how many rows it was asked for and wrote", ctx do
    %{conn: conn, admin: admin} = ctx
    first = printable(unique("Umbrella "))
    second = printable(unique("Hooli "))
    {:ok, view, _html} = conn |> log_in(admin) |> live(@page)

    ref = attach([[:ash_quick, :bulk, :run, :stop]])

    render_change(view, "table-form-change", %{first.id => "on", second.id => "on"})
    view |> element(@bulk, @print) |> render_click()
    confirm(view)

    assert_received {[:ash_quick, :bulk, :run, :stop], ^ref, %{duration: _, written: 2},
                     %{
                       quick_view: PrintableLive.Quick,
                       resource: Printable,
                       action: :print,
                       type: :update,
                       selected: 2,
                       status: :success
                     }}
  end

  test "an export is timed in the task that writes it", %{conn: conn, admin: admin} do
    ref = attach([[:ash_quick, :export, :stop]])
    {:ok, view, _html} = conn |> log_in(admin) |> live(~p"/products")

    view |> element("a", "CSV") |> render_click()
    render_async(view, to_timeout(second: 5))

    assert_received {[:ash_quick, :export, :stop], ^ref, %{duration: _},
                     %{
                       resource: Example.Catalog.Product,
                       format: :csv,
                       selection: :all,
                       result: :ok
                     }}
  end

  test "an export over the ceiling is reported as refused", %{conn: conn, admin: admin} do
    Application.put_env(:ash_quick, :export_max_rows, 1)
    on_exit(fn -> Application.delete_env(:ash_quick, :export_max_rows) end)
    product(name: unique("Tent "), actor: admin)
    product(name: unique("Lamp "), actor: admin)

    ref = attach([[:ash_quick, :export, :stop]])
    {:ok, view, _html} = conn |> log_in(admin) |> live(~p"/products")

    view |> element("a", "Excel") |> render_click()
    render_async(view, to_timeout(second: 5))

    assert_received {[:ash_quick, :export, :stop], ^ref, _,
                     %{format: :xlsx, result: :too_many_rows}}
  end

  # The modal offers two formats. Any other is a forged event, refused before
  # a span could carry the string it named.
  test "an export naming a format the modal does not offer runs nothing", ctx do
    %{conn: conn, admin: admin} = ctx

    ref =
      attach([
        [:ash_quick, :export, :start],
        [:ash_quick, :export, :exception]
      ])

    {:ok, view, _html} = conn |> log_in(admin) |> live(~p"/products")

    render_click(view, "export", %{"format" => String.duplicate("x", 300)})
    render_click(view, "export", %{"format" => "json"})

    refute has_element?(view, "#ash-quick-export-modal")
    refute_received {[:ash_quick, :export, _], ^ref, _, _}

    # And the page still exports what it offers.
    view |> element("a", "CSV") |> render_click()
    render_async(view, to_timeout(second: 5))
    assert has_element?(view, "#ash-quick-export-modal a", "Download")
  end
end
