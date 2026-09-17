defmodule ExampleWeb.TenancyScenarioTest do
  @moduledoc """
  Two shops on one installation, and nothing on a page that says so.

  `Example.Scope` carries the actor's store as the Ash tenant, and
  `Example.Catalog.Product` declares `multitenancy` over `:store_id`. Between
  them that is the whole of it: no QuickView mentions a store, no policy names
  one, and no page filters by one — the scope is passed to every action and the
  resource does the rest.

  Which makes this exactly the kind of thing worth driving rather than
  asserting at the action. A tenant that silently stops being applied does not
  raise anywhere; it shows one shop another shop's catalogue, on pages that
  look completely healthy.

  `global? true` is the second half, and the half a single-tenant test would
  miss: a reader with *no* store sees every store's products. That is what
  makes platform staff possible at all, and it means "the filter is off" and
  "this reader is platform staff" produce identical pages — so every test here
  pairs a scoped reader against an unscoped one.
  """
  use ExampleWeb.FeatureCase, async: true

  require Ash.Query

  alias Example.Accounts.AuditLog
  alias Example.Catalog.{Product, Store}

  setup %{admin: admin} do
    north = store(name: "Northwind Online", actor: admin)
    south = store(name: "Southgate Supply", actor: admin)

    %{
      north: north,
      south: south,
      # One shopkeeper per store, and a product in each.
      north_keeper: user(:editor, name: "Nora North", store: north, actor: admin),
      south_keeper: user(:editor, name: "Sam South", store: south, actor: admin),
      north_tent: product(name: "Northwind tent", store: north, actor: admin),
      south_tent: product(name: "Southgate tent", store: south, actor: admin),
      platform_tent: product(name: "Platform tent", actor: admin)
    }
  end

  describe "a reader inside a store" do
    test "sees their own catalogue and nobody else's", ctx do
      %{conn: conn, north_keeper: keeper} = ctx

      conn
      |> log_in(keeper)
      |> visit(~p"/products")
      |> assert_has("td", text: ctx.north_tent.name)
      |> refute_has("td", text: ctx.south_tent.name)
      # Not even the platform's own, which belongs to no store: the filter is
      # `store_id == tenant`, and null is not their store either.
      |> refute_has("td", text: ctx.platform_tent.name)
    end

    test "is scoped by the store they belong to, not by what their role may do", ctx do
      %{conn: conn, north: north, north_tent: north_tent, south_tent: south_tent} = ctx

      # An admin who belongs to a store is that store's admin. `global? true`
      # widens the read for a reader carrying no tenant at all — it is not a
      # role exemption, and the platform staff elsewhere in this file see every
      # shop because they belong to none, not because of what they may write.
      north_admin = user(:admin, name: "Nadia North", store: north)

      assert north_admin.store_id == north.id

      conn
      |> log_in(north_admin)
      |> visit(~p"/products")
      |> assert_has("td", text: north_tent.name)
      |> refute_has("td", text: south_tent.name)
      |> refute_has("td", text: ctx.platform_tent.name)
    end

    test "cannot reach another store's record by its id", ctx do
      %{conn: conn, north_keeper: keeper, south_tent: south_tent} = ctx

      # A row they cannot read is indistinguishable from one that is not there,
      # which is the right answer — knowing a uuid is not permission.
      conn
      |> log_in(keeper)
      |> visit(~p"/products/#{south_tent.id}")
      |> refute_has("h1", text: south_tent.name)
      |> assert_has("h1", text: "404")

      # The same URL, opened by somebody who may read it, is the record — so the
      # 404 above is about the tenant and not about the page being broken.
      conn
      |> log_in(ctx.admin)
      |> visit(~p"/products/#{south_tent.id}")
      |> assert_has("h1", text: south_tent.name)
    end

    test "cannot find it by searching for it either", ctx do
      %{conn: conn, north_keeper: keeper, south_tent: south_tent} = ctx

      # The search runs through the same read, so it narrows within the tenant
      # rather than reaching across it.
      conn
      |> log_in(keeper)
      |> visit(~p"/products?search=tent")
      |> assert_has("td", text: ctx.north_tent.name)
      |> refute_has("td", text: south_tent.name)
      |> visit(~p"/products?search=#{south_tent.sku}")
      |> refute_has("td", text: south_tent.name)
    end

    test "writes into their own store without being asked which", ctx do
      %{conn: conn, north_keeper: keeper, north: north} = ctx

      brand = brand(name: "Northwind Outfitters", actor: ctx.admin)
      category = category(name: "Tents", actor: ctx.admin)
      sku = unique("SKU")

      conn
      |> log_in(keeper)
      |> visit(~p"/products/create")
      |> fill_in("Sku", with: sku)
      |> fill_in("Name", with: "Freshly stocked")
      |> fill_in("Price", with: "75.00")
      |> select_entry("Brand", brand.name)
      |> select_entry("Category", category.name)
      |> click_button("Save")

      created = by_sku(sku)

      # Nothing on the form named a store. The tenant on the scope is what
      # stamped it, which is the property that makes a tenant seam worth having
      # over a filter somebody has to remember.
      assert created.store_id == north.id
    end

    test "is one of two, and the other sees the mirror image", ctx do
      %{conn: conn, south_keeper: keeper} = ctx

      # The pairing is what makes the refutals above mean something: each store's
      # keeper is refused exactly what the other is shown, so neither assertion
      # can be passing because the page is simply broken.
      conn
      |> log_in(keeper)
      |> visit(~p"/products")
      |> assert_has("td", text: ctx.south_tent.name)
      |> refute_has("td", text: ctx.north_tent.name)
      |> refute_has("td", text: ctx.platform_tent.name)
    end
  end

  describe "a reader with no store" do
    test "sees every store's catalogue, which is what global? buys", ctx do
      %{conn: conn, admin: admin} = ctx

      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> assert_has("td", text: ctx.north_tent.name)
      |> assert_has("td", text: ctx.south_tent.name)
      |> assert_has("td", text: ctx.platform_tent.name)
      # And the page says which is whose, so "everything" is legible rather
      # than just larger.
      |> assert_has("td", text: ctx.north.name)
      |> assert_has("td", text: ctx.south.name)
    end

    test "can open a record from either store", ctx do
      %{conn: conn, admin: admin} = ctx

      for product <- [ctx.north_tent, ctx.south_tent, ctx.platform_tent] do
        conn
        |> log_in(admin)
        |> visit(~p"/products/#{product.id}")
        |> assert_has("h1", text: product.name)
      end
    end
  end

  describe "standing in for a shopkeeper" do
    test "puts the tab in their store, not in the admin's absence of one", ctx do
      %{conn: conn, admin: admin, north_keeper: keeper} = ctx

      token = impersonation_token(conn, admin, keeper)

      # The tenant is read off whoever the tab is *acting as*. An admin looking
      # into a shop's problem sees the shop's catalogue — which is the whole
      # reason to stand in for somebody rather than read their rows as yourself.
      conn
      |> log_in(admin)
      |> impersonating(token)
      |> visit(~p"/products")
      |> assert_has("[data-ash-quick-impersonating]")
      |> assert_has("td", text: ctx.north_tent.name)
      |> refute_has("td", text: ctx.south_tent.name)
      |> refute_has("td", text: ctx.platform_tent.name)

      # Their own other tab still sees everything, so the narrowing followed the
      # tab rather than the login.
      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> assert_has("td", text: ctx.south_tent.name)
    end
  end

  describe "the tenant a write happened under" do
    test "is on the audit row, without the action recording it", ctx do
      %{conn: conn, north_keeper: keeper, north: north, north_tent: tent} = ctx

      conn
      |> log_in(keeper)
      |> visit(~p"/products/#{tent.id}/update")
      |> fill_in("Name", with: "Renamed in the shop")
      |> click_button("Save")
      |> assert_has("h1", text: "Renamed in the shop")

      entry =
        AuditLog
        |> Ash.Query.filter(resource_id == ^tent.id and action_name == :update)
        |> Ash.read_one!(authorize?: false)

      # The store is on the trail because the scope carried it, not because
      # anything about the product's update mentions one — so an entry can be
      # attributed to a tenant even for an action that has no tenant field.
      assert entry.tenant == north.id

      # And a write with no store behind it records none rather than guessing.
      # Read as the one entry it is rather than the first of an unsorted read:
      # the platform's tent is only ever created, so a second entry here is a
      # setup that changed under the test rather than a row to pick between.
      platform_entry =
        AuditLog
        |> Ash.Query.filter(resource_id == ^ctx.platform_tent.id)
        |> Ash.read_one!(authorize?: false)

      assert is_nil(platform_entry.tenant)
    end
  end

  describe "the tenant resource itself" do
    test "is not partitioned by the thing it is the partition for", ctx do
      %{conn: conn, admin: admin, north_keeper: keeper} = ctx

      refute Ash.Resource.Info.multitenancy_strategy(Store)
      assert Ash.Resource.Info.multitenancy_strategy(Product) == :attribute

      # A shopkeeper reads stores — their own name is rendered through this
      # action wherever they are shown — and holds no route to the page.
      assert Ash.can?({Store, :read}, keeper)

      assert_raise ExampleWeb.NotAllowedError, fn ->
        live(log_in(conn, keeper), ~p"/stores")
      end

      conn
      |> log_in(admin)
      |> visit(~p"/stores")
      |> assert_has("td", text: ctx.north.name)
      |> assert_has("td", text: ctx.south.name)
    end
  end

  defp by_sku(sku) do
    Product
    |> Ash.Query.filter(sku == ^sku)
    |> Ash.read_one!(authorize?: false, tenant: nil)
  end

  defp impersonation_token(conn, real_actor, target) do
    target_tab = new_tab()

    {:ok, _target_view, _html} =
      live(conn |> log_in(target) |> in_tab(target_tab), ~p"/products")

    {:ok, console, _html} = live(log_in(conn, real_actor), ~p"/browser_sessions")

    console
    |> element("#session-#{target_tab["id"]} button", "Open as them")
    |> render_click()

    assert_push_event(console, "impersonate", %{token: token})
    token
  end
end
