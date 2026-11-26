defmodule ExampleWeb.Browser.ImpersonationTest do
  @moduledoc """
  A tab's identity and its impersonation, in real browsers: the client half
  `withAshQuick` and `attachAshQuick` add (`assets/js/browser_session.js` and
  `assets/js/locale.js`).

  Impersonation belongs to a tab. The token lives in the tab's
  `sessionStorage` and rides the LiveSocket's connect params, so starting one
  takes the tab to the other person's page and reconnects it as them, a
  reload keeps it, and ending it reconnects the tab as whoever signed in. The
  page's `<html lang dir>` was written by the dead render, as the real user,
  so the connected mount pushes the language the tab is really in, and the
  tab applies it. `ExampleWeb.ImpersonationScenarioTest` drives the server's
  half with tabs made by hand.

  Two browsers here: an editor who reads Arabic, on a page, and an admin who
  reads English, opening that page as them from the live sessions register.
  """
  use ExampleWeb.BrowserCase

  setup context do
    %{admin: admin, editor: editor} = roles()
    editor = Ash.update!(editor, %{locale: :ar}, authorize?: false)
    product(name: unique("Ridge tent "), actor: admin)

    # A second browser, with its own cookies and storage, sharing this test's
    # database transaction.
    [conn: editor_conn] = PhoenixTest.Playwright.Case.do_setup(context)

    %{admin: admin, editor: editor, editor_conn: editor_conn}
  end

  defp tab(conn), do: read(conn, "JSON.parse(sessionStorage.getItem('ash_quick:tab'))")

  defp token(conn), do: read(conn, "sessionStorage.getItem('ash_quick:impersonation')")

  defp page_language(conn) do
    read(conn, "[document.documentElement.lang, document.documentElement.dir]")
  end

  test "a tab opened as somebody else becomes them in their language, until it ends", ctx do
    %{conn: conn, admin: admin, editor: editor, editor_conn: editor_conn} = ctx

    editor_conn =
      editor_conn
      |> log_in(editor)
      |> visit(~p"/products")
      |> connected()

    assert page_language(editor_conn) == ["ar", "rtl"]
    %{"id" => editor_tab} = tab(editor_conn)

    conn =
      conn
      |> log_in(admin)
      |> visit(~p"/browser_sessions")
      |> connected()

    %{"id" => admin_tab, "started_at" => started_at} = tab(conn)
    assert page_language(conn) == ["en", "ltr"]
    assert token(conn) == nil

    # The admin's tab goes to the editor's page and reconnects as them: their
    # language, their direction, and a banner that says so.
    conn =
      conn
      |> click(~s([id="session-#{editor_tab}"] button[phx-click=impersonate]))
      |> assert_path(~p"/products")
      |> connected()
      |> assert_has("[data-ash-quick-impersonating]", text: editor.name)
      |> assert_has("html[lang=ar][dir=rtl]")

    assert is_binary(token(conn))
    # Still the same tab: its identity is minted once and replayed.
    assert %{"id" => ^admin_tab, "started_at" => ^started_at} = tab(conn)

    # A reload's dead render is the admin's again; the tab replays its token
    # as it connects and is the editor once more.
    conn =
      conn
      |> reload_page()
      |> connected()
      |> assert_has("[data-ash-quick-impersonating]", text: editor.name)
      |> assert_has("html[lang=ar][dir=rtl]")

    assert %{"id" => ^admin_tab} = tab(conn)

    # Ending it drops the token and reconnects the tab as the admin.
    conn =
      conn
      |> click("[data-ash-quick-impersonating] button")
      |> refute_has("[data-ash-quick-impersonating]")
      |> assert_has("html[lang=en][dir=ltr]")

    assert token(conn) == nil

    # The editor's own tab was never touched.
    assert page_language(editor_conn) == ["ar", "rtl"]
    assert token(editor_conn) == nil
  end

  # The host's user menu dispatches `ash_quick:clear-impersonation` from its
  # Sign out link (`AshQuick.LiveView.Impersonation.clear_impersonation/1`).
  test "signing out ends the tab's impersonation with it", ctx do
    %{conn: conn, admin: admin, editor: editor, editor_conn: editor_conn} = ctx

    editor_conn =
      editor_conn
      |> log_in(editor)
      |> visit(~p"/products")
      |> connected()

    %{"id" => editor_tab} = tab(editor_conn)

    conn =
      conn
      |> log_in(admin)
      |> visit(~p"/browser_sessions")
      |> connected()
      |> click(~s([id="session-#{editor_tab}"] button[phx-click=impersonate]))
      |> assert_has("[data-ash-quick-impersonating]")

    assert is_binary(token(conn))

    conn =
      conn
      |> click("nav .dropdown:has(a[href='/sign-out']) > [role=button]")
      |> click("a[href='/sign-out']")
      |> assert_path(~p"/login")

    assert token(conn) == nil
  end
end
