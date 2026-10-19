defmodule ExampleWeb.PageDefaultTest do
  @moduledoc """
  A list nobody sized reads its action's `default_limit`.

  Over `Example.Test.DefaultPages`, whose list action opens at two rows and
  allows up to five. Its ETS table is written by this module alone, once, so
  the counts below are the whole table.
  """
  use ExampleWeb.ConnCase, async: true

  alias Example.Test.DefaultPages

  setup_all do
    for n <- 1..7 do
      DefaultPages
      |> Ash.Changeset.for_create(:create, %{code: "Default row #{n}"})
      |> Ash.create!(authorize?: false)
    end

    :ok
  end

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  test "a bare path reads a page of the action's default", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/test/default_pages")

    assert html =~ "Showing 1-2 of 7"
    assert has_element?(view, "td", "Default row 2")
    refute has_element?(view, "td", "Default row 3")

    # Four pages of two, not one of twenty.
    assert has_element?(view, ".join a", "4")
  end

  test "and pages through it at that size", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/test/default_pages?page=2")

    assert html =~ "Showing 3-4 of 7"
    assert has_element?(view, "td", "Default row 3")
    refute has_element?(view, "td", "Default row 5")
  end

  test "a limit the URL names wins over the default", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/test/default_pages?limit=4")

    assert html =~ "Showing 1-4 of 7"
  end

  test "the list behind the create modal reads the default too", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/test/default_pages/create")

    assert has_element?(view, "#ash-quick-action-modal")
    assert html =~ "Showing 1-2 of 7"
  end

  test "the URL leaves the default unsaid and keeps any other size", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/test/default_pages")

    navigate(view, ~p"/test/default_pages?limit=2")
    assert_patch(view, ~p"/test/default_pages")

    # The old default is a size like any other here, so it stays, held to the
    # ceiling.
    navigate(view, ~p"/test/default_pages?limit=20")
    assert_patch(view, ~p"/test/default_pages?limit=5")
    assert render(view) =~ "Showing 1-5 of 7"

    navigate(view, ~p"/test/default_pages?limit=3")
    refute_patched(view)
    assert render(view) =~ "Showing 1-3 of 7"
  end

  # A record page measures a limit against the list it links back to, not a
  # default of its own, so a size the visitor chose survives the round trip.
  test "a record page links back to the list at the size it was opened with", %{conn: conn} do
    [row | _rows] = Ash.read!(DefaultPages, authorize?: false)

    {:ok, view, _html} = live(conn, ~p"/test/default_pages")
    navigate(view, ~p"/test/default_pages/#{row.id}?limit=20")
    assert_patch(view, ~p"/test/default_pages/#{row.id}?limit=5")

    view |> element("a:has(.hero-arrow-left)") |> render_click()
    assert_patch(view, ~p"/test/default_pages?limit=5")
    assert render(view) =~ "Showing 1-5 of 7"
  end

  test "and one opened at the list's default links back without a limit", %{conn: conn} do
    [row | _rows] = Ash.read!(DefaultPages, authorize?: false)

    {:ok, view, _html} = live(conn, ~p"/test/default_pages")
    navigate(view, ~p"/test/default_pages/#{row.id}?limit=2")
    assert_patch(view, ~p"/test/default_pages/#{row.id}")
  end

  test "the create modal keeps a limit the visitor chose", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/test/default_pages/create?limit=20")

    assert has_element?(view, "#ash-quick-action-modal")
    assert html =~ "Showing 1-5 of 7"

    {:ok, view, _html} = live(conn, ~p"/test/default_pages")
    navigate(view, ~p"/test/default_pages/create?limit=20")
    assert_patch(view, ~p"/test/default_pages/create?limit=5")
  end

  # A list other than the default sizes its own page, and a record opened from
  # it links back to the default list, measured against that list's default.
  test "a second list opens at its own default, and its records link back to the default list",
       %{conn: conn} do
    newest = DefaultPages |> Ash.Query.sort(code: :desc) |> Ash.read_first!(authorize?: false)

    {:ok, view, html} = live(conn, ~p"/test/default_pages?action=newest_first")
    assert html =~ "Showing 1-3 of 7"
    assert has_element?(view, "td", "Default row 7")
    refute has_element?(view, "td", "Default row 4")

    # Its default is unsaid, so the record links back to the default list's.
    view |> element(~s(a[href="/test/default_pages/#{newest.id}"])) |> render_click()
    assert_patch(view, ~p"/test/default_pages/#{newest.id}")

    view |> element("a:has(.hero-arrow-left)") |> render_click()
    assert_patch(view, ~p"/test/default_pages")
    assert render(view) =~ "Showing 1-2 of 7"

    # A size the visitor chose there survives the round trip.
    {:ok, view, html} = live(conn, ~p"/test/default_pages?action=newest_first&limit=4")
    assert html =~ "Showing 1-4 of 7"

    view |> element(~s(a[href="/test/default_pages/#{newest.id}?limit=4"])) |> render_click()
    assert_patch(view, ~p"/test/default_pages/#{newest.id}?limit=4")

    view |> element("a:has(.hero-arrow-left)") |> render_click()
    assert_patch(view, ~p"/test/default_pages?limit=4")
    assert render(view) =~ "Showing 1-4 of 7"
  end

  # Two to five leaves no size on the ladder between them, so there is
  # nothing to pick until the URL names one.
  test "offers no page size select when the default is the only size", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/test/default_pages")
    refute has_element?(view, "#page-size")

    {:ok, view, _html} = live(conn, ~p"/test/default_pages?limit=4")
    assert has_element?(view, "#page-size option[selected]", "4")

    view |> element("#page-size-form") |> render_change(%{"limit" => "2"})
    assert_patch(view, ~p"/test/default_pages")
    refute has_element?(view, "#page-size")
  end

  test "a forged page size is held to the ceiling", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/test/default_pages?limit=4")

    view |> element("#page-size-form") |> render_change(%{"limit" => "1000"})
    assert_patch(view, ~p"/test/default_pages?limit=5")
    assert render(view) =~ "Showing 1-5 of 7"
  end

  # `render_patch/2` patches to the path itself first; what the page does
  # about it is the patch after that.
  defp navigate(view, path) do
    render_patch(view, path)
    assert_patch(view, path)
  end
end
