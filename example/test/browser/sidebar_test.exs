defmodule ExampleWeb.Browser.SidebarTest do
  @moduledoc """
  The sidebar's drawer on a phone, in a real browser
  (`AshQuick.LiveView.Components.Sidebar`). Below `lg` it waits off the
  screen, past the line's start: the left in English, the right in Arabic.
  Its toggle slides it in over a backdrop, and the backdrop or an entry
  slides it out again. The classes it swaps are `JS` commands, so only a
  browser runs them, and only a browser lays out where the drawer ends up.
  """
  use ExampleWeb.BrowserCase,
    parameterize: [%{locale: :en}, %{locale: :ar}]

  @moduletag browser_context_opts: [viewport: %{width: 390, height: 844}]

  setup %{locale: locale} do
    %{admin: admin} = roles()
    %{admin: Ash.update!(admin, %{locale: locale}, authorize?: false)}
  end

  # Where the drawer sits once it has finished sliding.
  defp drawer(conn) do
    read(conn, """
    (() => {
      const aside = document.getElementById("default-sidebar")
      return Promise.all(aside.getAnimations().map(a => a.finished)).then(() => {
        const box = aside.getBoundingClientRect()
        return {left: box.left, right: box.right, width: window.innerWidth}
      })
    })()
    """)
  end

  defp assert_out(conn, locale) do
    tap(conn, fn conn ->
      case {locale, drawer(conn)} do
        {:en, %{"right" => right}} -> assert right <= 0
        {:ar, %{"left" => left, "width" => width}} -> assert left >= width
      end
    end)
  end

  defp assert_in(conn) do
    tap(conn, fn conn ->
      %{"left" => left, "right" => right, "width" => width} = drawer(conn)
      assert left >= 0
      assert right <= width
    end)
  end

  test "its toggle slides it in over a backdrop, and the backdrop slides it out",
       %{conn: conn, admin: admin, locale: locale} do
    conn
    |> log_in(admin)
    |> visit(~p"/products")
    |> connected()
    |> refute_has("#sidebar-backdrop")
    |> assert_out(locale)
    |> click("#sidebar-toggle")
    |> assert_has("#sidebar-backdrop")
    |> assert_in()
    # Tapped beside the drawer, which covers the backdrop's middle.
    |> tap(&read(&1, "document.getElementById('sidebar-backdrop').click() || true"))
    |> refute_has("#sidebar-backdrop")
    |> assert_out(locale)
  end

  # The next page draws a new drawer, shut, before the entry's own close
  # lands on the old one (it never does: the old drawer is gone a frame
  # on), so this pins what the reader sees, not that close.
  test "an entry picked goes to its page with the drawer shut",
       %{conn: conn, admin: admin, locale: locale} do
    conn
    |> log_in(admin)
    |> visit(~p"/products")
    |> connected()
    |> click("#sidebar-toggle")
    |> assert_has("#sidebar-backdrop")
    |> assert_in()
    |> click("#default-sidebar a[href='/brands']")
    |> assert_path(~p"/brands")
    |> refute_has("#sidebar-backdrop")
    |> assert_out(locale)
  end

  # The entry of the page the reader is on patches the page rather than
  # drawing a new one, so the drawer it was picked from has to shut itself.
  test "the entry of the page it is on slides it out",
       %{conn: conn, admin: admin, locale: locale} do
    conn
    |> log_in(admin)
    |> visit(~p"/products?search=tent")
    |> connected()
    |> click("#sidebar-toggle")
    |> assert_has("#sidebar-backdrop")
    |> click("#default-sidebar a[href^='/products']")
    |> refute_has("#sidebar-backdrop")
    |> assert_out(locale)
  end

  # From `lg` up the sidebar is pinned with the drawer's classes still on it,
  # so an entry picked there must leave them shut: a toggle would flip them
  # to open, and the drawer would cover the page once the window narrows.
  @tag browser_context_opts: [viewport: %{width: 1280, height: 800}]
  test "an entry picked where it is pinned leaves the drawer shut for a phone",
       %{conn: conn, admin: admin, locale: locale} do
    conn
    |> log_in(admin)
    |> visit(~p"/products?search=tent")
    |> connected()
    |> click("#default-sidebar a[href^='/products']")
    |> assert_has("input[value='tent']")
    |> tap(&resize(&1, 390, 844))
    |> refute_has("#sidebar-backdrop")
    |> assert_out(locale)
  end

  # PhoenixTest.Playwright has no resize step, so this sends Playwright's own.
  defp resize(conn, width, height) do
    response =
      PlaywrightEx.Connection.send(
        PlaywrightEx.Supervisor.Connection,
        %{
          guid: conn.page_id,
          method: :setViewportSize,
          params: %{viewportSize: %{width: width, height: height}}
        },
        5000
      )

    refute Map.has_key?(response, :error), inspect(response)
  end
end
