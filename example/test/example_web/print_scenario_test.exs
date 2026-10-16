defmodule ExampleWeb.PrintScenarioTest do
  @moduledoc """
  Actions that print, run through a real QuickView page.

  An action prints by carrying `AshQuick.Print`; nothing else on the page knows
  about it. Whichever surface ran the action (a row action, a bulk selection,
  the details page, an action form), the records it returned are rendered after
  it committed and the PDF is pushed to the tab as an `"ash_quick:pdf"` event.
  The suite renders through `Example.Test.PdfRendererDouble`, whose "PDF" is
  the template's HTML, so what a print says is read off that event.

  The actions are on `Example.Test.Printable`, a resource of the test build,
  at `/test/printable`: all print through `Example.Test.Printable.Sheet` but
  `:print_faulty`, whose template raises.
  """
  use ExampleWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  alias Example.Test.{PdfRendererDouble, Printable}

  @page "/test/printable"
  @modal "#ash-quick-action-modal"
  @bulk "a[phx-click*='bulk_action']"
  # The `:print` entry alone, not every entry whose label starts with it.
  @print ~r/^\s*Print\s*$/
  @render_failed "It was recorded, but its PDF could not be produced. Print it again."

  # `%y-%m-%d-%H-%M-%S`, the moment the print was rendered.
  @stamp ~S"-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}\.pdf"

  describe "a print" do
    test "reaches the browser from every surface an action runs from", ctx do
      %{conn: conn, admin: admin, viewer: viewer} = ctx
      first = printable(unique("Northwind "))
      second = printable(unique("Globex "))

      {:ok, view, _html} = conn |> log_in(admin) |> live(@page)

      # A row action: confirmed in the modal, downloaded, named for the record.
      open_row_actions(view, first.id)
      view |> element("##{first.id}-action-print") |> render_click()
      confirm(view)

      assert_push_event(view, "ash_quick:pdf", %{delivery: :download} = event)
      assert event.filename =~ filename(first.name)
      assert printed_names(event) == [first.name]

      # A bulk selection: one PDF for every selected row, named for the count,
      # in the order the list shows them.
      tick_rows(view, [first.id, second.id])
      view |> element(@bulk, @print) |> render_click()
      confirm(view)

      assert_push_event(view, "ash_quick:pdf", %{delivery: :download} = event)
      assert event.filename =~ ~r/^printables_sheet_2#{@stamp}$/
      assert printed_names(event) == [second.name, first.name]

      # The details page.
      {:ok, view, _html} = conn |> log_in(admin) |> live("#{@page}/#{second.id}")

      view |> element("#details-more-actions-dropdown a", @print) |> render_click()
      confirm(view)

      assert_push_event(view, "ash_quick:pdf", %{delivery: :download} = event)
      assert event.filename =~ filename(second.name)
      assert printed_names(event) == [second.name]

      # An action form with an input: the print is of what the form wrote, and
      # this action opens the print dialog instead of saving a file.
      {:ok, view, _html} = conn |> log_in(admin) |> live(@page)
      renamed = unique("Initech ")

      open_row_actions(view, first.id)
      view |> element("##{first.id}-action-rename_and_print") |> render_click()

      view
      |> form("#{@modal} form[phx-submit=save]", %{"form" => %{"name" => renamed}})
      |> render_submit()

      assert_push_event(view, "ash_quick:pdf", %{delivery: :print} = event)
      assert event.filename =~ filename(renamed)
      assert printed_names(event) == [renamed]
      assert Ash.reload!(first, authorize?: false).name == renamed

      # A role that may not run the action is not offered it, on either page.
      # Both offer it to the admin above, so the refutals are about the role
      # rather than about an action that is never drawn.
      {:ok, view, _html} = conn |> log_in(viewer) |> live(@page)
      open_row_actions(view, second.id)
      assert has_element?(view, "tr[id='#{second.id}']", second.name)
      refute has_element?(view, "##{second.id}-action-print")

      {:ok, view, _html} = conn |> log_in(viewer) |> live("#{@page}/#{second.id}")
      assert render(view) =~ second.name
      refute has_element?(view, "#details-more-actions-dropdown a", @print)
    end

    test "of a bulk run follows the rows in the order the list shows them", ctx do
      %{conn: conn, admin: admin} = ctx
      tag = unique("Order ")

      # Created out of name order, so the order of their ids is not the order
      # the list sorts them in, by name.
      zulu = printable("#{tag} Zulu")
      alpha = printable("#{tag} Alpha")
      mike = printable("#{tag} Mike")

      {:ok, view, _html} = conn |> log_in(admin) |> live(@page)

      tick_rows(view, [zulu.id, alpha.id, mike.id])
      view |> element(@bulk, @print) |> render_click()
      confirm(view)

      assert_push_event(view, "ash_quick:pdf", event)
      assert printed_names(event) == [alpha.name, mike.name, zulu.name]
    end

    test "whose render fails keeps the write, says so and pushes nothing", ctx do
      %{conn: conn, admin: admin} = ctx
      record = printable(unique("Umbrella "))

      {:ok, view, _html} = conn |> log_in(admin) |> live(@page)

      open_row_actions(view, record.id)
      view |> element("##{record.id}-action-print_faulty") |> render_click()

      # The template names the records it failed on, so this is this test's
      # failure and not another's logged at the same time.
      assert capture_log(fn -> confirm(view) end) =~ "cannot render #{record.name}"
      assert has_element?(view, "#flash-error", @render_failed)
      refute_push_event(view, "ash_quick:pdf", _event)

      # The action committed before the render was tried, and stays committed.
      assert %DateTime{} = Ash.reload!(record, authorize?: false).printed_at

      # The page is still up and still takes the next print.
      open_row_actions(view, record.id)
      view |> element("##{record.id}-action-print") |> render_click()
      confirm(view)

      assert_push_event(view, "ash_quick:pdf", event)
      assert printed_names(event) == [record.name]
    end

    test "of a bulk run that wrote no row is not made", ctx do
      %{conn: conn, admin: admin} = ctx
      first = printable(unique("Stale "))
      second = printable(unique("Stale "))

      {:ok, view, _html} = conn |> log_in(admin) |> live(@page)
      tick_rows(view, [first.id, second.id])

      # Both rows move behind the page, so the lock matches neither.
      move_behind_the_view(first)
      move_behind_the_view(second)

      view |> element(@bulk, @print) |> render_click()
      confirm(view)

      assert has_element?(view, "#flash-error", "Print applied to 0 of 2 selected rows.")
      refute_push_event(view, "ash_quick:pdf", _event)
    end

    test "is not made by an action that does not carry it", ctx do
      %{conn: conn, admin: admin} = ctx
      record = printable(unique("Plain "))

      {:ok, view, _html} = conn |> log_in(admin) |> live(@page)

      open_row_actions(view, record.id)
      view |> element("##{record.id}-action-destroy") |> render_click()
      confirm(view)

      assert {:error, _not_found} = Ash.get(Printable, record.id, authorize?: false)
      refute_push_event(view, "ash_quick:pdf", _event)
    end
  end

  # `:print_if_active` prints only what passes its `where:`, and a bulk
  # selection can mix the two. The print is of the rows it marked, in the
  # list's order, whichever row comes first.
  describe "a print behind a condition" do
    setup do
      %{tag: unique("Cond ")}
    end

    test "over a selection led by a row it excludes prints the rows it marked", ctx do
      %{conn: conn, admin: admin, tag: tag} = ctx
      excluded = printable("#{tag} Alpha", active: false)
      bravo = printable("#{tag} Bravo")
      charlie = printable("#{tag} Charlie")

      event = bulk_print_if_active(conn, admin, [excluded, bravo, charlie])

      assert printed_names(event) == [bravo.name, charlie.name]
      assert event.filename =~ ~r/^printables_sheet_2#{@stamp}$/
      assert Ash.reload!(excluded, authorize?: false).printed_at == nil
    end

    test "over a selection led by a row it marks leaves out the rows it excludes", ctx do
      %{conn: conn, admin: admin, tag: tag} = ctx
      alpha = printable("#{tag} Alpha")
      excluded = printable("#{tag} Bravo", active: false)
      charlie = printable("#{tag} Charlie")

      event = bulk_print_if_active(conn, admin, [alpha, excluded, charlie])

      assert printed_names(event) == [alpha.name, charlie.name]
      assert event.filename =~ ~r/^printables_sheet_2#{@stamp}$/
      assert Ash.reload!(excluded, authorize?: false).printed_at == nil
    end

    test "over a selection it excludes entirely prints nothing", ctx do
      %{conn: conn, admin: admin, tag: tag} = ctx
      first = printable("#{tag} Alpha", active: false)
      second = printable("#{tag} Bravo", active: false)

      {:ok, view, _html} = conn |> log_in(admin) |> live(@page)
      tick_rows(view, [first.id, second.id])
      view |> element(@bulk, "Print If Active") |> render_click()
      confirm(view)

      refute has_element?(view, "#flash-error")
      refute_push_event(view, "ash_quick:pdf", _event)
    end
  end

  defp bulk_print_if_active(conn, admin, records) do
    {:ok, view, _html} = conn |> log_in(admin) |> live(@page)
    tick_rows(view, Enum.map(records, & &1.id))
    view |> element(@bulk, "Print If Active") |> render_click()
    confirm(view)

    # Every selected row was run, the excluded ones included.
    refute has_element?(view, "#flash-error")
    assert_push_event(view, "ash_quick:pdf", event)
    event
  end

  defp printable(name, opts \\ []) do
    Printable
    |> Ash.Changeset.for_create(:create, %{
      code: unique("P"),
      name: name,
      active: Keyword.get(opts, :active, true)
    })
    |> Ash.create!(authorize?: false)
  end

  defp open_row_actions(view, id) do
    view |> element("##{id}-row-actions-dropdown [role=button]") |> render_click()
  end

  defp tick_rows(view, ids) do
    render_change(view, "table-form-change", Map.new(ids, &{&1, "on"}))
  end

  # The Confirm button submits the modal's form, which is what pressing it
  # sends.
  defp confirm(view) do
    assert has_element?(view, "#{@modal} form button[type=submit]", "Confirm")
    view |> form("#{@modal} form") |> render_submit()
  end

  # Bumps the version and tells nobody, so the page still holds the old one.
  defp move_behind_the_view(record) do
    Ash.Seed.update!(record, %{version: record.version + 1})
  end

  defp filename(name), do: ~r/^#{Regex.escape(name)}_sheet#{@stamp}$/

  # The records the template rendered, in the order it rendered them.
  defp printed_names(event) do
    event
    |> PdfRendererDouble.printed_pdf()
    |> String.replace_prefix("%PDF-1.4\n", "")
    |> LazyHTML.from_document()
    |> LazyHTML.query("[data-name]")
    |> Enum.flat_map(&LazyHTML.attribute(&1, "data-name"))
  end
end
