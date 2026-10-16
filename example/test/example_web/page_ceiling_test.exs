defmodule ExampleWeb.PageCeilingTest do
  @moduledoc """
  A list holds `?limit=` to its action's `max_page_size`.

  Ash clamps the read to the same number, so the rows were never the risk.
  The page's own arithmetic was: the offset, the footer and the pager all come
  from the limit the page holds, and one Ash quietly lowered sends each of them
  somewhere the read did not go.

  Over `Example.Test.SmallPages`, whose list action reads at most three rows.
  Its ETS table is written by this module alone, once, so the counts below are
  the whole table.
  """
  use ExampleWeb.ConnCase, async: true

  alias Example.Test.SmallPages

  setup_all do
    for n <- 1..7 do
      SmallPages
      |> Ash.Changeset.for_create(:create, %{code: "Small row #{n}"})
      |> Ash.create!(authorize?: false)
    end

    :ok
  end

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  test "a limit past the action's ceiling reads a page of the ceiling", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/test/small_pages?limit=100000")

    assert html =~ "Showing 1-3 of 7"
    assert has_element?(view, "td", "Small row 3")
    refute has_element?(view, "td", "Small row 4")
  end

  test "and pages through the rows that size actually holds", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/test/small_pages?limit=100000&page=2")

    assert html =~ "Showing 4-6 of 7"
    assert has_element?(view, "td", "Small row 4")
    refute has_element?(view, "td", "Small row 3")
    refute has_element?(view, "td", "Small row 7")

    # Three pages of three, not one of 100,000.
    assert has_element?(view, ".join a", "3")
    refute has_element?(view, ".join a", "4")
  end

  # A page bounded against the limit the URL asked for would be cut to the
  # second, since a billion rows leave room for only two pages.
  test "a page is held to what the clamped size can reach, not the asked one", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/test/small_pages?limit=1000000000&page=3")

    assert html =~ "Showing 7-7 of 7"
    assert has_element?(view, "td", "Small row 7")
  end

  # The list behind the create modal is resolved apart from the page's own
  # action, so it is clamped apart from it too.
  test "the list behind the create modal is held to the ceiling", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/test/small_pages/create?limit=100000&page=2")

    assert has_element?(view, "#ash-quick-action-modal")
    assert html =~ "Showing 4-6 of 7"
  end

  test "the page nobody sized is held to the ceiling too", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/test/small_pages")

    assert html =~ "Showing 1-3 of 7"
  end

  test "the URL is corrected to the size the page read", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/test/small_pages")

    # The ceiling is also the default here, so the corrected URL leaves it
    # unsaid, the way a bare path reads it.
    navigate(view, ~p"/test/small_pages?limit=100000")
    assert_patch(view, ~p"/test/small_pages")

    # A size under the ceiling is the visitor's, and stays in the URL.
    navigate(view, ~p"/test/small_pages?limit=2")
    refute_patched(view)
    assert render(view) =~ "Showing 1-2 of 7"
  end

  # `render_patch/2` patches to the path itself first; what the page does
  # about it is the patch after that.
  defp navigate(view, path) do
    render_patch(view, path)
    assert_patch(view, path)
  end
end
