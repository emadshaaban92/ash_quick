defmodule ExampleWeb.Browser.ActionModalTest do
  @moduledoc """
  The action modal in a real browser
  (`AshQuick.LiveView.Components.ActionModal`) and the lock on a form while
  it submits (`AshQuick.Components.SubmitLock`).

  The modal is a real modal dialog: it takes the focus itself, Escape does
  not close it (only its ✕ and Cancel do), and once it closes the focus goes
  back to what opened it. Opened from a row's menu, the menu's hook returns
  the focus as well, so the cases that pin the modal's own return open it
  from a list's Create button and a details page's action button: neither
  carries an id, and both are drawn again, as new nodes, under the modal,
  so the modal finds the new one by the event its click pushes. While its
  form submits, its ✕ is a disabled twin, and the boxes and selects in
  the form refuse what would change them, the clicks and keys a browser
  would otherwise act on.

  `liveSocket.enableLatencySim/1` holds every message to the server for a
  moment, which is what keeps the form submitting long enough to try.
  """
  use ExampleWeb.BrowserCase,
    parameterize: [%{locale: :en}, %{locale: :ar}]

  alias Example.Test.{CheckboxWidths, DatedEntries}

  @modal "#ash-quick-action-modal"
  @box "document.querySelector('#ash-quick-action-modal #form_active')"

  setup %{locale: locale} do
    %{admin: admin} = roles()
    admin = Ash.update!(admin, %{locale: locale}, authorize?: false)
    record = Ash.create!(CheckboxWidths, %{code: unique("W"), active: false}, authorize?: false)
    %{admin: admin, record: record, row: "#{record.id}-row-actions-dropdown"}
  end

  defp open_update(conn, admin, row, record) do
    conn
    |> log_in(admin)
    |> visit("/test/checkbox_widths")
    |> connected()
    |> press(~s([id="#{row}-trigger"]), "Enter")
    |> assert_has(~s([id="#{record.id}-action-update"]:focus))
    |> press(":focus", "Enter")
    |> assert_has("#{@modal} form")
  end

  defp focused(conn), do: read(conn, "document.activeElement.id")

  defp slow(conn, ms), do: tap(conn, &read(&1, "liveSocket.enableLatencySim(#{ms}) || true"))

  defp fast(conn), do: tap(conn, &read(&1, "liveSocket.disableLatencySim() || true"))

  test "opens as a modal that holds the focus, and Escape leaves it open", ctx do
    %{conn: conn, admin: admin, row: row, record: record} = ctx
    conn = open_update(conn, admin, row, record)

    assert read(conn, "document.querySelector('#{@modal}').matches(':modal')")
    assert focused(conn) == "ash-quick-action-modal"

    conn
    |> press(@modal, "Escape")
    |> press(@modal, "Escape")
    |> assert_has(@modal)
    |> tap(&assert(read(&1, "document.querySelector('#{@modal}').matches(':modal')")))

    # Tab goes on to its first control, inside it.
    conn = press(conn, @modal, "Tab")
    assert read(conn, "document.querySelector('#{@modal}').contains(document.activeElement)")
  end

  test "its ✕ closes it and hands the focus back to the row's menu button", ctx do
    %{conn: conn, admin: admin, row: row, record: record} = ctx

    conn
    |> open_update(admin, row, record)
    |> click("#{@modal} a[aria-label]:not([data-close-while-submitting])")
    |> refute_has(@modal)
    |> assert_has(~s([id="#{row}-trigger"]:focus))
  end

  test "Cancel closes it and hands the focus back too", ctx do
    %{conn: conn, admin: admin, row: row, record: record} = ctx

    conn
    |> open_update(admin, row, record)
    |> click("#{@modal} form a[href], #{@modal} form button[type=button]")
    |> refute_has(@modal)
    |> assert_has(~s([id="#{row}-trigger"]:focus))
  end

  # Opened from a row's menu, the menu hands the focus back to its button by
  # itself (`reclaim()` in the Menus hook). Opened from any other control, only
  # the modal can: opening it draws the page under it again, the Create button
  # with it, and the button carries no id, so the modal finds the new one by
  # the event its click pushes.
  test "opened from the list's Create button, it hands the focus back to it", ctx do
    %{conn: conn, admin: admin} = ctx
    create = "button:has(> .hero-plus)"

    conn
    |> log_in(admin)
    |> visit("/test/checkbox_widths")
    |> connected()
    |> press(create, "Enter")
    |> assert_has("#{@modal} form")
    |> click("#{@modal} a[aria-label]:not([data-close-while-submitting])")
    |> refute_has(@modal)
    |> assert_has("#{create}:focus")
    |> press(create, "Enter")
    |> assert_has("#{@modal} form")
    |> click("#{@modal} form a[href], #{@modal} form button[type=button]")
    |> refute_has(@modal)
    |> assert_has("#{create}:focus")
  end

  # The same, for a details page's action buttons.
  test "opened from a details page's button, it hands the focus back to it", ctx do
    %{conn: conn, admin: admin, record: record} = ctx
    update = ~s|button[phx-click*='"action_name":"update"']|

    conn =
      conn
      |> log_in(admin)
      |> visit("/test/checkbox_widths/#{record.id}")
      |> connected()
      |> press(update, "Enter")
      |> assert_has("#{@modal} form")

    assert focused(conn) == "ash-quick-action-modal"

    conn
    |> click("#{@modal} a[aria-label]:not([data-close-while-submitting])")
    |> refute_has(@modal)
    |> assert_has("#{update}:focus")
    |> press(update, "Enter")
    |> assert_has("#{@modal} form")
    |> click("#{@modal} form a[href], #{@modal} form button[type=button]")
    |> refute_has(@modal)
    |> assert_has("#{update}:focus")
  end

  test "while its form submits, the ✕ is disabled and a box refuses a click or a key",
       ctx do
    %{conn: conn, admin: admin, row: row, record: record} = ctx

    conn
    |> open_update(admin, row, record)
    |> fill_in("#{@modal} #form_note", "Note", with: "Saved while locked")
    |> slow(1500)
    |> click("#{@modal} form button[type=submit]")
    |> assert_has("#{@modal} form.phx-submit-loading")
    |> assert_has("#{@modal} button[data-close-while-submitting][disabled]")
    |> refute_has("#{@modal} a[aria-label]:not([data-close-while-submitting])")
    # A pointer cannot reach it (`phx-submit-loading:pointer-events-none`),
    # but a click from a label, a script or assistive technology can.
    |> tap(&refute(read(&1, "(b => (b.click(), b.checked))(#{@box})")))
    |> press("#{@modal} #form_active", " ")
    |> tap(&refute(read(&1, "#{@box}.checked")))
    |> fast()
    |> refute_has(@modal)

    assert %{active: false, note: "Saved while locked"} =
             Ash.get!(CheckboxWidths, record.id, authorize?: false)
  end

  # A closed select's keys change nothing in a headless Chromium, so this
  # asks what the lock does with them: every key but Tab is cancelled.
  test "while its form submits, a select's keys are cancelled, but Tab's", ctx do
    %{conn: conn, admin: admin} = ctx

    entry =
      Ash.create!(DatedEntries, %{code: unique("E"), stamped_at: ~U[2026-01-15 12:00:00.000000Z]},
        authorize?: false
      )

    conn =
      conn
      |> log_in(admin)
      |> visit("/test/dated_entries/#{entry.id}/update")
      |> connected()

    refute cancelled?(conn, "ArrowDown")

    conn
    |> slow(1500)
    |> click("form button[type=submit]")
    |> assert_has("form.phx-submit-loading")
    |> tap(&assert(cancelled?(&1, "ArrowDown")))
    |> tap(&assert(cancelled?(&1, "End")))
    |> tap(&refute(cancelled?(&1, "Tab")))
    |> fast()
    |> refute_has("form.phx-submit-loading")
  end

  defp cancelled?(conn, key) do
    read(conn, """
    (() => {
      const event = new KeyboardEvent("keydown", {key: "#{key}", bubbles: true, cancelable: true})
      document.getElementById("form_stamped_at-zone").dispatchEvent(event)
      return event.defaultPrevented
    })()
    """)
  end
end
