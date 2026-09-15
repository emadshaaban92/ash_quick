defmodule ExampleWeb.HostileParamsTest do
  @moduledoc """
  A QuickView list reached with a query string nobody's controls wrote.

  The parse itself is unit-tested in the package. What that cannot show is that
  the page survives: each of these once took the mount down from
  `handle_params/3`, which needs a router, an endpoint and a live socket to
  see — none of which the package has.
  """
  use ExampleWeb.ConnCase, async: true

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  test "a limit that is not a number lists the page at the default size", %{
    conn: conn,
    admin: admin
  } do
    product(name: "Four-season tent", actor: admin)

    {:ok, _view, html} = live(conn, ~p"/products?limit=abc")

    assert html =~ "Four-season tent"
  end

  test "a limit past the ceiling is read at the ceiling, not as asked", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/products?limit=100000")

    assert page_limit(view) == 250
  end

  test "a page before the first lists the first", %{conn: conn, admin: admin} do
    product(name: "Four-season tent", actor: admin)

    {:ok, _view, html} = live(conn, ~p"/products?page=-5")

    assert html =~ "Four-season tent"
  end

  test "a page deeper than the data layer can offset reads the deepest page", %{conn: conn} do
    # `?page=-5` above is the near end of this; the far end is page × limit
    # leaving the range of a 64-bit offset. Mounting at all is the assertion.
    {:ok, view, _html} = live(conn, ~p"/products?page=99999999999999999999")

    assert page_read(view) == div(1_000_000_000, page_limit(view)) + 1
  end

  test "a read argument naming nothing is not passed to the action", %{conn: conn, admin: admin} do
    product(name: "Four-season tent", actor: admin)

    {:ok, _view, html} = live(conn, ~p"/products?arg__no_such_argument_anywhere=1")

    assert html =~ "Four-season tent"
  end

  test "a custom filter that does not decode lists everything", %{conn: conn, admin: admin} do
    product(name: "Four-season tent", actor: admin)

    # Two shapes, because base64 fails differently depending on what is wrong
    # with it: `"!!!!"` raises `ArgumentError`, and `"0"` — a likelier
    # truncation — is one of the many that do not.
    for custom_filter <- ["!!!!", "0"] do
      {:ok, _view, html} = live(conn, ~p"/products?custom_filter=#{custom_filter}")

      assert html =~ "Four-season tent"
    end
  end

  defp page_limit(view) do
    :sys.get_state(view.pid).socket.assigns.data.limit
  end

  defp page_read(view) do
    :sys.get_state(view.pid).socket.assigns.params.page
  end
end
