defmodule ExampleWeb.DownloadScenarioTest do
  @moduledoc """
  Actions that produce a file of their own, run through a real QuickView page.

  An action delivers a file by marking the record it returns with
  `:ash_quick_download`; AshQuick never sets the mark. Whichever surface ran
  the action (a row action, a bulk selection, the details page, an action
  form), each marked record's file is pushed to the tab as an
  `"ash_quick:download"` event once the action has committed, its bytes
  base64-encoded.

  The actions are on `Example.Test.Downloadable`, a resource of the test
  build, at `/test/downloadable`, and mark through
  `Example.Test.Downloadable.Watermark`.
  """
  use ExampleWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  alias Example.Test.Downloadable
  alias Example.Test.Downloadable.Watermark

  @page "/test/downloadable"
  @modal "#ash-quick-action-modal"
  @bulk "a[phx-click*='bulk_action']"
  # The `:watermark` entry alone, not every entry whose label starts with it.
  @watermark ~r/^\s*Watermark\s*$/
  @not_delivered "It was recorded, but its file could not be delivered."

  describe "a file an action produced" do
    test "reaches the browser from every surface an action runs from", ctx do
      %{conn: conn, admin: admin} = ctx
      first = downloadable(unique("Northwind "))
      second = downloadable(unique("Globex "))

      {:ok, view, _html} = conn |> log_in(admin) |> live(@page)

      # A row action, confirmed in the modal.
      open_row_actions(view, first.id)
      view |> element("##{first.id}-action-watermark") |> render_click()
      confirm(view)

      assert_delivered(view, first)

      # The details page.
      {:ok, view, _html} = conn |> log_in(admin) |> live("#{@page}/#{second.id}")

      view |> element("#details-more-actions-dropdown a", @watermark) |> render_click()
      confirm(view)

      assert_delivered(view, second)

      # An action form with an input: the file is of what the form wrote.
      {:ok, view, _html} = conn |> log_in(admin) |> live(@page)
      renamed = unique("Initech ")

      open_row_actions(view, first.id)
      view |> element("##{first.id}-action-rename_and_watermark") |> render_click()

      view
      |> form("#{@modal} form[phx-submit=save]", %{"form" => %{"name" => renamed}})
      |> render_submit()

      assert_delivered(view, %{first | name: renamed})
      assert Ash.reload!(first, authorize?: false).name == renamed
    end

    test "of a bulk run comes as one file per row, in the order the list shows them", ctx do
      %{conn: conn, admin: admin} = ctx
      tag = unique("Order ")

      # Created out of name order, so the order of their ids is not the order
      # the list sorts them in, by name.
      zulu = downloadable("#{tag} Zulu")
      alpha = downloadable("#{tag} Alpha")
      mike = downloadable("#{tag} Mike")

      {:ok, view, _html} = conn |> log_in(admin) |> live(@page)

      tick_rows(view, [zulu.id, alpha.id, mike.id])
      view |> element(@bulk, @watermark) |> render_click()
      confirm(view)

      assert_delivered(view, alpha)
      assert_delivered(view, mike)
      assert_delivered(view, zulu)
      refute_push_event(view, "ash_quick:download", _event)
    end

    test "of a bulk run comes only for the rows the action marked", ctx do
      %{conn: conn, admin: admin} = ctx
      tag = unique("Cond ")
      excluded = downloadable("#{tag} Alpha", active: false)
      bravo = downloadable("#{tag} Bravo")
      charlie = downloadable("#{tag} Charlie")

      {:ok, view, _html} = conn |> log_in(admin) |> live(@page)

      tick_rows(view, [excluded.id, bravo.id, charlie.id])
      view |> element(@bulk, "Watermark If Active") |> render_click()
      confirm(view)

      refute has_element?(view, "#flash-error")
      assert_delivered(view, bravo)
      assert_delivered(view, charlie)
      refute_push_event(view, "ash_quick:download", _event)
      assert Ash.reload!(excluded, authorize?: false).watermarked_at == nil
    end

    test "is not pushed by an action that does not mark its record", ctx do
      %{conn: conn, admin: admin} = ctx
      touched = downloadable(unique("Plain "))
      destroyed = downloadable(unique("Plain "))

      {:ok, view, _html} = conn |> log_in(admin) |> live(@page)

      open_row_actions(view, touched.id)
      view |> element("##{touched.id}-action-touch") |> render_click()
      confirm(view)

      assert %DateTime{} = Ash.reload!(touched, authorize?: false).watermarked_at

      open_row_actions(view, destroyed.id)
      view |> element("##{destroyed.id}-action-destroy") |> render_click()
      confirm(view)

      assert {:error, _not_found} = Ash.get(Downloadable, destroyed.id, authorize?: false)
      refute has_element?(view, "#flash-error")
      refute_push_event(view, "ash_quick:download", _event)
      refute_push_event(view, "ash_quick:pdf", _event)
    end

    test "whose mark is malformed keeps the write, says so and pushes nothing", ctx do
      %{conn: conn, admin: admin} = ctx
      record = downloadable(unique("Umbrella "))

      {:ok, view, _html} = conn |> log_in(admin) |> live(@page)

      open_row_actions(view, record.id)
      view |> element("##{record.id}-action-watermark_malformed") |> render_click()

      log = capture_log(fn -> confirm(view) end)

      # The log says what is wrong with the mark, not what it holds.
      assert log =~ "#{inspect(Downloadable)} marked for download could not be delivered"
      assert log =~ "missing or invalid :data, :content_type"
      refute log =~ Watermark.filename(record)

      assert has_element?(view, "#flash-error", @not_delivered)
      refute_push_event(view, "ash_quick:download", _event)

      # The action committed before the file was looked at, and stays committed.
      assert %DateTime{} = Ash.reload!(record, authorize?: false).watermarked_at

      # The page is still up and still delivers the next file.
      open_row_actions(view, record.id)
      view |> element("##{record.id}-action-watermark") |> render_click()
      confirm(view)

      assert_delivered(view, record)
    end
  end

  # The next download pushed is `record`'s file, under its name and type, its
  # bytes base64-encoded.
  defp assert_delivered(view, record) do
    assert_push_event(view, "ash_quick:download", event)

    assert event == %{
             data: Base.encode64(Watermark.bytes(record)),
             filename: Watermark.filename(record),
             content_type: "application/octet-stream"
           }
  end

  defp downloadable(name, opts \\ []) do
    Downloadable
    |> Ash.Changeset.for_create(:create, %{
      code: unique("D"),
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
end
