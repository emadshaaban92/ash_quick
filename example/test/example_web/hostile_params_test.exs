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

  import ExUnit.CaptureLog

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

  describe "a custom filter the resource refuses" do
    # `from_string/1` decodes this one correctly — it is a structurally valid
    # filter, and nothing at the parse knows the resource. Only the read can
    # tell, and it used to tell by raising `Ash.Error.Query.NoSuchField` from
    # inside `handle_params/3`, which took the mount down.
    test "lists everything rather than exiting the view", %{conn: conn, admin: admin} do
      product(name: "Four-season tent", actor: admin)

      {:ok, _view, html} = live(conn, ~p"/products?custom_filter=#{refused_filter()}")

      assert html =~ "Four-season tent"
    end

    test "says the filter was ignored rather than dropping it silently", %{
      conn: conn,
      admin: admin
    } do
      product(name: "Four-season tent", actor: admin)

      {:ok, view, _html} = live(conn, ~p"/products?custom_filter=#{refused_filter()}")

      assert render(view) =~ "That filter couldn&#39;t be applied to this list"
    end

    # The filter is gone from the params the page was built from, so the
    # address bar is corrected to match — the same treatment `?custom_filter=0`
    # gets for failing a layer earlier.
    test "is dropped from the URL the visitor is left looking at", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/products")

      assert assert_patch(navigate(view, "/products?custom_filter=#{refused_filter()}")) ==
               "/products"
    end

    # The flash names the filter whatever actually raised, so without this a
    # read that merely failed once leaves no trace but a wrong explanation.
    test "and the error behind it is logged rather than discarded", %{conn: conn, admin: admin} do
      product(name: "Four-season tent", actor: admin)

      log =
        capture_log(fn ->
          {:ok, _view, _html} = live(conn, ~p"/products?custom_filter=#{refused_filter()}")
        end)

      assert log =~ "No such field no_such_field"
      # And the filter it fired on, which the flash deliberately does not name.
      assert log =~ ~s(field_name: "no_such_field")
    end

    # The second way a filter fails, and the one that is not only a hostile-URL
    # case: `filter_input/2` takes a real field without checking the value, so
    # an uncastable one is refused by the *data layer* instead. `FilterForm`
    # renders a free-text value box for UUID, money and date columns, so this
    # is reachable by typing `abc` into a filter rather than by editing a URL.
    test "a real field with a value its type cannot cast is dropped too", %{
      conn: conn,
      admin: admin
    } do
      product(name: "Four-season tent", actor: admin)

      for filter <- [
            %{"operator" => "equals", "field_name" => "price", "value" => "not-a-number"},
            %{"operator" => "equals", "field_name" => "id", "value" => "not-a-uuid"}
          ] do
        {:ok, view, html} = live(conn, ~p"/products?custom_filter=#{encode_filter(filter)}")

        assert html =~ "Four-season tent"
        assert render(view) =~ "That filter couldn&#39;t be applied to this list"
      end
    end

    # The negative: naming a field the resource *does* have still filters, so
    # the drop is not reading every custom filter as refused.
    test "a filter naming a real field still filters", %{conn: conn, admin: admin} do
      product(name: "Four-season tent", actor: admin)
      product(name: "Three-season tent", actor: admin)

      {:ok, _view, html} =
        live(conn, ~p"/products?custom_filter=#{name_filter("Four-season tent")}")

      assert html =~ "Four-season tent"
      refute html =~ "Three-season tent"
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

  # `URI.encode_query/1` has no `String.Chars` for a map and refuses a list
  # outright, and `full_path/2` now runs on every pass rather than only where a
  # list page built its pager links — so a read argument that is not a string
  # would take down every shape rather than one.
  test "a read argument the query cannot express does not take the page down", %{
    conn: conn,
    admin: admin
  } do
    product = product(name: "Four-season tent", actor: admin)

    for url <- [
          ~p"/products?arg__search[a]=1",
          ~p"/products?arg__search[]=1",
          ~p"/products/#{product.id}?arg__search[a]=1",
          ~p"/products/#{product.id}?arg__search[]=1"
        ] do
      assert {:ok, _view, html} = live(conn, url)
      assert html =~ "Four-season tent"
    end
  end

  describe "a URL reached at a path the parsed params do not rebuild" do
    # `/create` takes its action from the router's `live_action`, not from a URL
    # param, so `params.action` is `nil` and `full_path/2` writes the bare base
    # path for it. Patching to *that* would put the visitor on the list, which
    # is why the canonical path is asked for by shape instead.
    test "a create URL keeps its form rather than being sent to the list", %{conn: conn} do
      for url <- [
            ~p"/products/create",
            ~p"/products/create?limit=abc",
            ~p"/products/create?return_to=%2Fdashboard"
          ] do
        {:ok, view, html} = live(conn, url)

        assert page_action(view) == :create
        assert html =~ "phx-submit"
      end
    end

    # The gap this describe block used to pin open. A create form renders none
    # of the list concerns, so a query naming them describes a page that was
    # never built: `?limit=abc` a page size nothing used, `?custom_filter=` a
    # filter nothing decoded.
    test "and its query is corrected under the create path, not away from it", %{conn: conn} do
      cases = [
        {"/products/create?limit=abc", "/products/create"},
        {"/products/create?page=-5", "/products/create"},
        {"/products/create?custom_filter=0", "/products/create"},
        {"/products/create?return_to=%2Fdashboard", "/products/create"}
      ]

      for {asked, canonical} <- cases do
        {:ok, view, _html} = live(conn, ~p"/products")

        assert assert_patch(navigate(view, asked)) == canonical
      end
    end

    # `/create` carries no `:id` segment, and `action_from_params/3` had no
    # clause for the combination — a stray param on a link exited the mount.
    test "and an id it has nowhere to put is ignored rather than fatal", %{
      conn: conn,
      admin: admin
    } do
      product = product(name: "Four-season tent", actor: admin)

      for url <- [
            ~p"/products/create?id=#{product.id}",
            ~p"/products/create?action=quick_add&id=#{product.id}"
          ] do
        {:ok, view, html} = live(conn, url)

        assert html =~ "phx-submit"
        # Dropped, not merely unused: a create form has no record to name.
        assert page_id(view) == nil
      end
    end

    # And dropping it is what carries it out of the address bar too.
    test "and that id is gone from the URL the visitor is left looking at", %{
      conn: conn,
      admin: admin
    } do
      product = product(name: "Four-season tent", actor: admin)

      {:ok, view, _html} = live(conn, ~p"/products")

      assert assert_patch(navigate(view, "/products/create?id=#{product.id}")) ==
               "/products/create"
    end

    # The negative that matters most here: the corrected URL is one the page
    # will not correct again. Every patch is another request, so a create path
    # that did not compare equal to itself would not be a cosmetic bug — it
    # would be a loop.
    test "and the corrected URL is then left alone", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/products")

      assert refute_patched(navigate(view, "/products/create")) == :ok
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

    # And so is anything riding along with it. `?action=` is what makes the
    # rebuilt path disagree with the one being served, and that disagreement is
    # the whole refusal — there is no correcting the rest of the query without
    # also deciding to rewrite the path, which is the one thing this never does.
    test "including a query alongside it that nothing used", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/products")

      assert refute_patched(navigate(view, "/products/create?action=quick_add&limit=abc")) == :ok
    end

    # `?action=` can name any read the resource has. A stock `read` takes no
    # search argument, and used to raise from inside `handle_params/3`.
    test "a read the list cannot be driven through is not found, not a crash", %{
      conn: conn,
      admin: admin
    } do
      product(name: "Four-season tent", actor: admin)

      {:ok, view, _html} = live(conn, ~p"/products?action=read")

      assert render(view) =~ "404"
      # The same answer a name the resource does not define gets.
      assert page_action(view) == nil
    end

    # The negative that matters: the guard is the lookup contract, not "a read
    # named in the query".
    test "and the list's own read still lists when the query names it", %{
      conn: conn,
      admin: admin
    } do
      product(name: "Four-season tent", actor: admin)

      {:ok, _view, html} = live(conn, ~p"/products?action=index")

      assert html =~ "Four-season tent"
    end

    # Nor is the contract asked of a shape that neither pages nor searches.
    test "while the same read still serves a details URL", %{conn: conn, admin: admin} do
      product = product(name: "Four-season tent", actor: admin)

      {:ok, _view, html} = live(conn, ~p"/products/#{product.id}?action=read")

      assert html =~ "Four-season tent"
    end

    # A write action named on a shape that does not serve it. Each of these
    # reached `do_handle_params/4` with no clause — except the last, which
    # matched the update clause on a nil id and blamed the visitor's
    # permissions for the record it then could not read.
    test "an action the shape does not serve is not found either", %{conn: conn, admin: admin} do
      product = product(name: "Four-season tent", actor: admin)

      for url <- [
            ~p"/products/#{product.id}?action=create",
            ~p"/products/#{product.id}?action=quick_add",
            ~p"/products?action=destroy",
            ~p"/products/create?action=update"
          ] do
        {:ok, view, _html} = live(conn, url)

        assert render(view) =~ "404"
        assert page_action(view) == nil
      end
    end

    # The negatives for the same clauses: each shape still serves what it is for.
    test "while each shape still serves the action it is for", %{conn: conn, admin: admin} do
      product = product(name: "Four-season tent", actor: admin)

      for {url, action} <- [
            {~p"/products", :index},
            {~p"/products/create", :create},
            {~p"/products/#{product.id}", :read},
            {~p"/products/#{product.id}/update", :update}
          ] do
        {:ok, view, _html} = live(conn, url)

        assert page_action(view) == action
      end
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

  # Decodes perfectly well; names a field `Example.Catalog.Product` does not
  # have. Written out rather than built through `CustomFilter`, because what is
  # under test is a URL nobody's controls wrote.
  defp refused_filter do
    encode_filter(%{"operator" => "equals", "field_name" => "no_such_field", "value" => "x"})
  end

  defp name_filter(name) do
    encode_filter(%{"operator" => "equals", "field_name" => "name", "value" => name})
  end

  defp encode_filter(filter), do: filter |> JSON.encode!() |> :base64.encode()

  # `nil` where the URL named an action this page cannot serve, which is the
  # assign the not-found render matches on.
  defp page_action(view) do
    case :sys.get_state(view.pid).socket.assigns.ash_action do
      nil -> nil
      action -> action.name
    end
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
