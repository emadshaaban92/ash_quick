defmodule AshQuick.LiveView.RouterTest.ScopedRouter do
  @moduledoc """
  A `quick_view` under a scope prefix, which is the only way to see what the
  macro pins as a base path diverge from what the route is served at.
  """
  use Phoenix.Router

  import AshQuick.LiveView.Router

  scope "/admin", AshQuick.Test.Nav do
    quick_view("/brands", BrandLive.Quick, only: [:index, :show])
  end
end

defmodule AshQuick.LiveView.RouterTest do
  @moduledoc """
  The `quick_view/3` macro decides its routes at compile time, so what it
  produces and what it refuses are checked directly — there is no request that
  can be made against a router that failed to compile.

  What is *not* here is the reconciliation a host runs over its own router, nav
  and access control. That is a statement about one application's four
  artifacts agreeing with each other, so it belongs to the application: the
  library cannot know which routes a host meant to grant. What the library owes
  it is below — the base path a route carries, and the refusal when there is
  none.
  """
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.QuickView
  alias AshQuick.LiveView.Router
  alias AshQuick.LiveView.RouterTest.ScopedRouter
  alias AshQuick.Test.Nav.BrandLive

  describe "which routes a quick_view declares" do
    test "all four by default, with create ahead of the id route that would swallow it" do
      assert Router.__routes__("/products", []) == [
               {"/products", nil},
               {"/products/create", :create},
               {"/products/:id", nil},
               {"/products/:id/:action", nil}
             ]
    end

    test ":only keeps declaration order regardless of how it was written" do
      assert Router.__routes__("/audit_logs", only: [:show, :index]) == [
               {"/audit_logs", nil},
               {"/audit_logs/:id", nil}
             ]
    end

    test ":except drops what it names" do
      assert Router.__routes__("/items", except: [:create]) == [
               {"/items", nil},
               {"/items/:id", nil},
               {"/items/:id/:action", nil}
             ]
    end

    test ":only and :except together is refused" do
      assert_raise ArgumentError, ~r/:only or :except, not both/, fn ->
        Router.__routes__("/products", only: [:index], except: [:create])
      end
    end

    test "a shape that does not exist is refused, and says these are not resource actions" do
      assert_raise ArgumentError, ~r/not resource actions/, fn ->
        Router.__routes__("/products", only: [:index, :publish])
      end
    end

    test "an empty selection is refused rather than declaring nothing" do
      assert_raise ArgumentError, ~r/:only expects a non-empty list/, fn ->
        Router.__routes__("/products", only: [])
      end

      assert_raise ArgumentError, ~r/leaves no routes at all/, fn ->
        Router.__routes__("/products", except: [:index, :create, :show, :action])
      end
    end
  end

  describe "a quick_view declared inside a scope" do
    setup do
      %{routes: Phoenix.Router.routes(ScopedRouter)}
    end

    test "is served under the scope prefix", %{routes: routes} do
      assert Enum.map(routes, & &1.path) == ["/admin/brands", "/admin/brands/:id"]
    end

    test "builds its links from the prefixed path, not the literal one", %{routes: routes} do
      for route <- routes do
        assert route.metadata.ash_quick.base_path == "/admin/brands"
      end
    end

    test "and the view reads that same path back off the route it was reached through" do
      socket = %Phoenix.LiveView.Socket{router: ScopedRouter, view: BrandLive.Quick}

      assert QuickView.base_path!(
               socket,
               URI.parse("http://localhost/admin/brands/#{Ash.UUID.generate()}")
             ) == "/admin/brands"
    end
  end

  describe "a QuickView reached through a route the macro did not declare" do
    test "says so, rather than rendering a page whose every link is broken" do
      # `/scan` is a plain `live/3` on the fixture router, so the route it
      # resolves to carries no base path for the view to read.
      socket = %Phoenix.LiveView.Socket{
        router: AshQuick.Test.Nav.Router,
        view: BrandLive.Quick
      }

      assert_raise RuntimeError, ~r/carries no AshQuick metadata/, fn ->
        QuickView.base_path!(socket, URI.parse("http://localhost/scan"))
      end
    end
  end
end
