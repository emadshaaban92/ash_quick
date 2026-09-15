defmodule ExampleWeb.NavAccessScenarioTest do
  @moduledoc """
  What each role is offered, and what happens when they reach past it.

  One list of routes is rendered three times — as the sidebar, as the apps
  grid, and as the mount-time gate — and nothing holds the three to each other
  at runtime. Two ways that goes wrong are invisible to a test that only asks
  `ExampleWeb.AccessControl.can_access?/2`:

    * a route granted to a role that no `group` in `ExampleWeb.Nav` names has a
      page and no tile leading to it, and
    * a route granted to a role whose *read policy* omits them has a link, and
      a page that is permanently empty, and never a 403 — because the policy
      filters rows rather than refusing the action.

  So the pages are driven. Each role's nav is asserted whole rather than
  spot-checked: a `refute_has` per page a role should not see would keep
  passing if a fourth page appeared that nobody thought to refute.
  """
  use ExampleWeb.FeatureCase, async: true

  require Ash.Query

  alias Example.Accounts.AuditLog
  alias Example.Catalog.Product

  setup %{admin: admin} do
    brand = brand(name: "Northwind Outfitters", actor: admin)
    category = category(name: "Tents", actor: admin)

    product =
      product(name: "Four-season tent", brand: brand, category: category, actor: admin)

    reprice(product, to: Money.new(:USD, "149.00"), actor: admin)

    %{
      brand: brand,
      category: category,
      product: product,
      store: store(name: "Northwind Online", actor: admin),
      object: file_object(actor: admin)
    }
  end

  describe "an admin" do
    test "is offered every page in the app, and each one has their records on it", ctx do
      %{conn: conn, admin: admin, brand: brand, category: category, product: product} = ctx

      assert sidebar(conn, admin) == [
               {"/", "Home"},
               {"/products", "Products"},
               {"/categories", "Categories"},
               {"/brands", "Brands"},
               {"/price_changes", "Price Changes"},
               {"/users", "Users"},
               {"/stores", "Stores"},
               {"/browser_sessions", "Live Users"},
               {"/audit_logs", "Audit Logs"},
               {"/file_objects", "File Objects"}
             ]

      # Only a group of more than one path earns a heading; `Audit` and
      # `Uploads` hold one page each and render as bare entries.
      assert headings(conn, admin) == ["Catalog", "Settings"]

      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> assert_has("td", text: product.name)
      |> visit(~p"/categories")
      |> assert_has("td", text: category.name)
      |> visit(~p"/brands")
      |> assert_has("td", text: brand.name)
      |> visit(~p"/price_changes")
      |> assert_has("td", text: product.name)
      |> visit(~p"/users")
      |> assert_has("td", text: admin.name)
      |> visit(~p"/stores")
      |> assert_has("td", text: ctx.store.name)
      |> visit(~p"/file_objects")
      |> assert_has("td", text: ctx.object.key)
      |> visit(~p"/audit_logs")
      |> assert_has("td", text: "Product")
      |> visit(~p"/browser_sessions")
      |> assert_has("h1, h2, h3", text: "Live Users")
    end
  end

  describe "an editor" do
    test "is offered the catalog and the uploads console, and is refused the rest", ctx do
      %{conn: conn, editor: editor, product: product} = ctx

      assert sidebar(conn, editor) == [
               {"/", "Home"},
               {"/products", "Products"},
               {"/categories", "Categories"},
               {"/brands", "Brands"},
               {"/price_changes", "Price Changes"},
               {"/file_objects", "File Objects"}
             ]

      # `Settings` disappears with its pages: a heading is drawn for the group,
      # and a group whose every path is filtered out is not a section at all.
      assert headings(conn, editor) == ["Catalog"]

      conn
      |> log_in(editor)
      |> visit(~p"/products")
      |> assert_has("td", text: product.name)
      |> visit(~p"/file_objects")
      |> assert_has("td", text: ctx.object.key)

      for denied <- ~w(/users /stores /audit_logs /browser_sessions) do
        assert_raise ExampleWeb.NotAllowedError, fn ->
          live(log_in(conn, editor), denied)
        end
      end
    end
  end

  describe "a viewer" do
    test "is offered the catalog alone, and is refused the rest", ctx do
      %{conn: conn, viewer: viewer, brand: brand, category: category, product: product} = ctx

      assert sidebar(conn, viewer) == [
               {"/", "Home"},
               {"/products", "Products"},
               {"/categories", "Categories"},
               {"/brands", "Brands"},
               {"/price_changes", "Price Changes"}
             ]

      # Every catalog page a viewer is granted has their records on it. This is
      # the pairing nothing else asserts: a read policy narrowed to exclude
      # viewers would leave all five links in place and every page blank, which
      # `can_access?/2` would still answer yes to.
      conn
      |> log_in(viewer)
      |> visit(~p"/products")
      |> assert_has("td", text: product.name)
      |> visit(~p"/categories")
      |> assert_has("td", text: category.name)
      |> visit(~p"/brands")
      |> assert_has("td", text: brand.name)
      |> visit(~p"/price_changes")
      |> assert_has("td", text: product.name)

      for denied <- ~w(/users /stores /audit_logs /file_objects /browser_sessions) do
        assert_raise ExampleWeb.NotAllowedError, fn ->
          live(log_in(conn, viewer), denied)
        end
      end
    end

    test "reaches a record under a route they hold, which prefix matching allows", ctx do
      %{conn: conn, viewer: viewer, product: product} = ctx

      # `/products` grants `/products/<id>` and nothing that merely starts with
      # the same letters — the rule `can_access?/2` documents, driven rather
      # than asserted against the function.
      conn
      |> log_in(viewer)
      |> visit(~p"/products/#{product.id}")
      |> assert_has("*", text: product.sku)
    end
  end

  describe "the apps grid" do
    test "is the same permission drawn as tiles, one per group the role can reach", ctx do
      %{conn: conn, admin: admin, editor: editor, viewer: viewer} = ctx

      assert tiles(conn, admin) == [
               {"/products", "Catalog"},
               {"/users", "Settings"},
               {"/audit_logs", "Audit"},
               {"/file_objects", "Uploads"}
             ]

      assert tiles(conn, editor) == [{"/products", "Catalog"}, {"/file_objects", "Uploads"}]
      assert tiles(conn, viewer) == [{"/products", "Catalog"}]
    end

    test "leads where it says it does", %{conn: conn, editor: editor, object: object} do
      conn
      |> log_in(editor)
      |> visit(~p"/")
      # The grid is on the page twice — the navbar's apps dropdown carries it
      # too — so the click names which one.
      |> within("main", &click_link(&1, "Uploads"))
      |> assert_has("td", text: object.key)
    end
  end

  describe "a role that loses its access mid-session" do
    test "is refused the next navigation, not only the first", ctx do
      %{conn: conn, admin: admin, product: product} = ctx

      # The gate is a `handle_params` hook, so it runs again on every
      # navigation. Demoting the admin between two visits is the cheapest way to
      # show the second one is really checked rather than decided at sign-in.
      session =
        conn
        |> log_in(admin)
        |> visit(~p"/audit_logs")
        |> assert_has("td", text: "Product")

      Ash.update!(admin, %{role: :viewer}, actor: admin, authorize?: false)

      assert_raise ExampleWeb.NotAllowedError, fn ->
        visit(session, ~p"/audit_logs")
      end

      # And what they still hold keeps working, so the refusal above is about
      # the route rather than about the session having gone bad.
      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> assert_has("td", text: product.name)
    end
  end

  describe "what the nav declares and what the router serves" do
    test "every route any role is granted is one this suite has driven" do
      # `ExampleWeb.AccessControl.all_routes/0` is what `mix ash_quick.check`
      # reconciles against the router and the nav. Naming the same list here
      # means a route added to a role but to no test above fails, rather than
      # being granted and never opened by anyone.
      driven =
        ~w(/ /brands /categories /products /price_changes /stores /users /audit_logs
           /file_objects /browser_sessions)

      assert Enum.sort(ExampleWeb.AccessControl.all_routes()) == Enum.sort(driven)
    end

    test "the audit trail behind all of this names the actor, not the page", ctx do
      %{product: product, admin: admin} = ctx

      # Every write in `setup` ran as the admin through a real action, so the
      # trail is the other rendering of the same permission story.
      trail =
        AuditLog
        |> Ash.Query.filter(resource_id == ^product.id)
        |> Ash.read!(authorize?: false, load: [:actor])

      assert Enum.map(trail, & &1.action_name) == [:create, :reprice]
      assert Enum.all?(trail, &(&1.actor.id == admin.id))
      assert Enum.all?(trail, &(&1.resource_name == Ash.Resource.Info.short_name(Product)))
    end
  end

  # --- Reading the two nav renderings off a page -----------------------------
  #
  # Asserted as whole lists, so a page that appears where it should not fails
  # here rather than waiting for someone to write a `refute_has` for it.

  defp sidebar(conn, user) do
    conn
    |> rendered(user)
    |> LazyHTML.query("#default-sidebar li > a")
    |> Enum.map(&{attribute(&1, "href"), text(&1)})
  end

  defp headings(conn, user) do
    conn
    |> rendered(user)
    |> LazyHTML.query("#default-sidebar li.menu-title")
    |> Enum.map(&text/1)
  end

  # The grid is rendered twice on a page that shows it — once in the navbar's
  # apps dropdown and once in the page body — and both are the same list.
  defp tiles(conn, user) do
    conn
    |> rendered(user)
    |> LazyHTML.query("div.grid > a")
    |> Enum.map(&{attribute(&1, "href"), text(&1)})
    |> Enum.uniq()
  end

  # `/products` rather than `/`: the home page is the apps grid, so it sets
  # `sidebar: false` and there would be no rail to read. Every role holds
  # `/products`, and the navbar carries the grid on every page.
  defp rendered(conn, user) do
    {:ok, _view, html} = live(log_in(conn, user), ~p"/products")
    LazyHTML.from_fragment(html)
  end

  defp attribute(element, name), do: element |> LazyHTML.attribute(name) |> List.first()
  defp text(element), do: element |> LazyHTML.text() |> String.trim()
end
