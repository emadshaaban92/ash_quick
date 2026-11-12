defmodule ExampleWeb.UncountedPagesTest do
  @moduledoc """
  A list whose action cannot be counted still reads, and pages forward and
  back without a total.

  Over `Example.Test.UncountedPages`, whose list action opens at two rows and
  declares `countable false`, and whose second list keeps Ash's default,
  `countable true`, which counts only when asked. Its
  ETS table is written by this module alone, once, so the seven rows below are
  the whole table.
  """
  use ExampleWeb.ConnCase, async: true

  alias Example.Test.UncountedPages

  setup_all do
    for n <- 1..7 do
      UncountedPages
      |> Ash.Changeset.for_create(:create, %{code: "Uncounted row #{n}"})
      |> Ash.create!(authorize?: false)
    end

    :ok
  end

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  test "the first page reads without a total and links to the next", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/test/uncounted_pages")

    assert html =~ "Showing 1-2"
    refute html =~ "Showing 1-2 of"
    assert has_element?(view, "td", "Uncounted row 2")
    refute has_element?(view, "td", "Uncounted row 3")

    refute has_element?(view, ~s(a[aria-label="Previous page"]))
    assert has_element?(view, ~s(a[aria-label="Next page"][href="/test/uncounted_pages?page=2"]))
    assert has_element?(view, ~s(.join [aria-current="page"]), "1")
  end

  test "a middle page links both ways", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/test/uncounted_pages?page=2")

    assert html =~ "Showing 3-4"
    assert has_element?(view, "td", "Uncounted row 3")

    assert has_element?(view, ~s(a[aria-label="Previous page"][href="/test/uncounted_pages"]))
    assert has_element?(view, ~s(a[aria-label="Next page"][href="/test/uncounted_pages?page=3"]))
    assert has_element?(view, ~s(.join [aria-current="page"]), "2")
  end

  test "the last page ends at its last row and offers no next", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/test/uncounted_pages?page=4")

    assert html =~ "Showing 7-7"
    assert has_element?(view, "td", "Uncounted row 7")

    assert has_element?(
             view,
             ~s(a[aria-label="Previous page"][href="/test/uncounted_pages?page=3"])
           )

    refute has_element?(view, ~s(a[aria-label="Next page"]))
  end

  # Without a count it cannot tell how far back the last row is, so it leads
  # to the first page rather than to page 8, which is empty too.
  test "a page past the last says it is empty and leads back to the first", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/test/uncounted_pages?page=9")

    assert html =~ "No results on this page"
    refute has_element?(view, "td", "Uncounted row 1")
    assert has_element?(view, ~s(a[aria-label="Previous page"][href="/test/uncounted_pages"]))
    refute has_element?(view, ~s(a[aria-label="Next page"]))
    # It knows of no rows to size.
    refute has_element?(view, "#page-size")
  end

  test "offers the page size select while there is more than a page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/test/uncounted_pages")

    assert has_element?(view, "#page-size option[selected]", "2")

    view |> element("#page-size-form") |> render_change(%{"limit" => "10"})
    assert_patch(view, ~p"/test/uncounted_pages?limit=10")

    html = render(view)
    assert html =~ "Showing 1-7"
    assert has_element?(view, "td", "Uncounted row 7")
    refute has_element?(view, ~s(a[aria-label="Next page"]))
    # Still offered: a list that fits on this page may not fit on the smaller.
    assert has_element?(view, "#page-size option[selected]", "10")
  end

  test "an action that counts on request is asked to", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/test/uncounted_pages?action=counted_on_request")

    assert html =~ "Showing 1-2 of 7"
    assert has_element?(view, ".join a", "4")
  end
end
