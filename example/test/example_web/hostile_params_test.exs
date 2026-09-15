defmodule ExampleWeb.HostileParamsTest do
  @moduledoc """
  A QuickView list reached with a query string nobody's controls wrote.

  The parse itself is unit-tested in the package. What that cannot show is that
  the page survives: each of these once took the mount down from
  `handle_params/3`, which needs a router, an endpoint and a live socket to
  see — none of which the package has.

  Nor can the package show the other half: that the address bar is corrected to
  say what the page actually did with the query, rather than keeping the promise
  the link made.
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

  describe "the URL the visitor is left looking at" do
    test "a query the parse could not take at face value is corrected", %{conn: conn} do
      cases = [
        {"/products?limit=abc", "/products"},
        {"/products?limit=100000", "/products?limit=250"},
        {"/products?page=-5", "/products"},
        {"/products?custom_filter=0", "/products"},
        {"/products?arg__no_such_argument_anywhere=1", "/products"}
      ]

      for {asked, canonical} <- cases do
        {:ok, view, _html} = live(conn, ~p"/products")

        assert assert_patch(navigate(view, asked)) == canonical
      end
    end

    # The negative that keeps the library from patching on every render of every
    # URL its own controls wrote — including the patch it just issued itself,
    # which is what turns a wrong comparison into an endless loop rather than a
    # cosmetic bug. `?page=2` is what the pager builds, so it has to be left
    # exactly as it is.
    test "a query its own controls would have written is left alone", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/products")

      assert refute_patched(navigate(view, "/products?page=2")) == :ok
    end

    # `path_no_params/2` rebuilds the `/:id` and `/:action` segments, so these
    # are the shapes a careless canonical path would patch away from.
    test "a details or action URL canonicalizes to itself", %{conn: conn, admin: admin} do
      product = product(name: "Four-season tent", actor: admin)

      for path <- ["/products/#{product.id}", "/products/#{product.id}/update"] do
        {:ok, view, _html} = live(conn, ~p"/products")

        assert refute_patched(navigate(view, path)) == :ok
      end
    end

    # Correcting the query is not something only the list page gets: the deeper
    # shapes keep their path and have the query corrected under it.
    test "a query is corrected under a details or action path too", %{
      conn: conn,
      admin: admin
    } do
      product = product(name: "Four-season tent", actor: admin)

      cases = [
        {"/products/#{product.id}?limit=abc", "/products/#{product.id}"},
        {"/products/#{product.id}/update?page=-5", "/products/#{product.id}/update"}
      ]

      for {asked, canonical} <- cases do
        {:ok, view, _html} = live(conn, ~p"/products")

        assert assert_patch(navigate(view, asked)) == canonical
      end
    end
  end

  describe "a URL naming its action in the query" do
    # The regression this guard exists for. `quick_view/3` serves four shapes —
    # `""`, `/create`, `/:id`, `/:id/:action` — and none of them is `/<action>`,
    # so `?action=` is the only way to reach a second create-type action. It is
    # also priority 1 of the resolution order the moduledoc documents.
    #
    # `full_path/2` writes that action into the *path*, where `/products/quick_add`
    # matches `/:id` and renders a product that does not exist. Canonicalizing
    # the path rather than the query turned a documented feature into a 404.
    test "a second create action is reached, not redirected into a missing record", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, ~p"/products/create?action=quick_add")

      assert html =~ "Quick Add"
      assert page_action(view) == :quick_add
      assert page_id(view) == nil
    end

    test "and its URL is left exactly as it came in", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/products")

      assert refute_patched(navigate(view, "/products/create?action=quick_add")) == :ok
    end

    # `?action=` on a details URL names a route that *does* exist, so rewriting
    # it to `/products/<id>/update` would land somewhere real. It is still left
    # alone: a path the host linked to deliberately is not this function's to
    # rewrite, and treating `?action=` the same way everywhere is what makes the
    # rule statable in one sentence — correct the query, never the path.
    test "a details URL naming its action in the query is left alone too", %{
      conn: conn,
      admin: admin
    } do
      product = product(name: "Four-season tent", actor: admin)

      {:ok, view, _html} = live(conn, ~p"/products")

      assert refute_patched(navigate(view, "/products/#{product.id}?action=update")) == :ok
    end
  end

  # Reaches `path` the way a link inside the page does, and hands back a view
  # whose remaining navigation is the page's own answer: `render_patch/2`
  # announces the navigation the test asked for, which is not the page saying
  # anything.
  defp navigate(view, path) do
    render_patch(view, path)
    assert_patch(view, path)
    view
  end

  defp page_action(view) do
    :sys.get_state(view.pid).socket.assigns.ash_action.name
  end

  defp page_id(view) do
    :sys.get_state(view.pid).socket.assigns.params.id
  end

  defp page_limit(view) do
    :sys.get_state(view.pid).socket.assigns.data.limit
  end

  defp page_read(view) do
    :sys.get_state(view.pid).socket.assigns.params.page
  end
end
