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

  # `render_patch/2` patches to the path itself first; what the page does
  # about it is the patch after that.
  defp navigate(view, path) do
    render_patch(view, path)
    assert_patch(view, path)
  end
end
