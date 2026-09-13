defmodule AshQuick.NavTest do
  @moduledoc """
  What a nav resolves to, over a router and a scope.

  The renderings are asserted where a user meets them — a host drives the
  sidebar and the apps grid against its own roles. What is here is what has no
  surface: the answer a declaration and a router produce together, and the
  declarations the DSL refuses to compile at all.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AshQuick.Nav.Info
  alias AshQuick.Test.Nav.AccessControl
  alias AshQuick.Test.Nav.Bare
  alias AshQuick.Test.Nav.Brand
  alias AshQuick.Test.Nav.Declared
  alias AshQuick.Test.Nav.Icons
  alias AshQuick.Test.Nav.Router
  alias AshQuick.Test.Nav.Scope

  defp scope(roles), do: %Scope{roles: roles}

  defp paths(sections) do
    Enum.map(sections, fn section ->
      {section.group && section.group.label, Enum.map(section.entries, & &1.path)}
    end)
  end

  describe "what the nav declares it is resolved against" do
    test "the router and the access control are read off the nav" do
      assert Info.router(Declared) == Router
      assert Info.access_control(Declared) == AccessControl
      assert Info.router(Bare) == nil
      assert Info.access_control(Bare) == nil
    end

    test "a nav is rendered against the router it declares" do
      assert Info.sections(scope([:admin]), Declared) ==
               Info.sections(scope([:admin]), Declared, Router)
    end

    # `Spark.Dsl` keeps a `use` option list only when the whole of it is a
    # quoted literal and substitutes an empty one otherwise, so a module
    # attribute here would leave both modules unset and the nav filtering
    # nothing, silently. Refusing to compile is the only answer that cannot be
    # missed.
    test "an option that is not a literal is refused rather than dropped" do
      source = """
      defmodule NavLiteralProbe#{:erlang.unique_integer([:positive])} do
        @router AshQuick.Test.Nav.Router

        use AshQuick.Nav, router: @router

        nav do
          entry("/scan", label: "Scan")
        end
      end
      """

      assert_raise ArgumentError, ~r/takes its options as literals/, fn ->
        Code.compile_string(source)
      end
    end
  end

  describe "what the router supplies" do
    test "a QuickView's four routes collapse onto the one path it is reached at" do
      assert Info.discovered(Router) == [{"/brands", Brand}]
    end

    test "a route the quick_view macro did not declare is not discovered" do
      refute "/scan" in Enum.map(Info.discovered(Router), &elem(&1, 0))
    end

    test "with no router configured, only what the nav declares exists" do
      assert Info.discovered(nil) == []

      assert Enum.map(Info.entries(Declared, nil), & &1.path) == ["/scan", "/brands", "/products"]
    end
  end

  describe "resolving an entry" do
    test "a QuickView nothing declares is still an entry, labelled from its resource" do
      assert [%{path: "/brands", label: "Brands", resource: Brand}] = Info.entries(nil, Router)
    end

    test "a declared label wins over the one the resource would give" do
      assert %{label: "Marques"} = entry(Declared, Router, "/brands")
    end

    test "a path with no resource behind it is labelled from its last segment" do
      assert %{label: "Scan", resource: nil} = entry(Declared, Router, "/scan")
    end

    test "an entry that declares no icon gets a generic one rather than none" do
      assert %{icon: "hero-rectangle-stack-solid"} = entry(Declared, Router, "/products")
    end

    test "a declared path the router does not serve is kept, not silently dropped" do
      # It is a typo, and one a host's reconciliation test names. Dropping it
      # here would hide the only evidence that it is wrong.
      assert %{path: "/products"} = entry(Declared, Router, "/products")
    end
  end

  describe "grouping" do
    test "a path named by two groups appears under both" do
      sections = Info.sections(scope([:admin]), Declared, Router)

      assert paths(sections) == [
               {nil, ["/products"]},
               {"Things", ["/brands", "/scan"]},
               {"Also Brands", ["/brands"]}
             ]
    end

    test "entries in no group come first, in one section with no heading" do
      assert [%{group: nil, entries: [%{path: "/products"}]} | _] =
               Info.sections(scope([:admin]), Declared, Router)
    end
  end

  describe "what a scope may not reach" do
    test "entries outside the scope's routes are dropped, and a group emptied with them" do
      # :catalog holds /products and /brands, but not /scan.
      sections = Info.sections(scope([:catalog]), Declared, Router)

      assert paths(sections) == [
               {nil, ["/products"]},
               {"Things", ["/brands"]},
               {"Also Brands", ["/brands"]}
             ]
    end

    test "a scope with no routes at all is offered nothing" do
      assert Info.sections(scope([]), Declared, Router) == []
    end

    test "a route grants the paths directly under it, and nothing that merely shares its prefix" do
      assert Info.allowed?("/scan", ["/scan"])
      assert Info.allowed?("/scan/history", ["/scan"])
      refute Info.allowed?("/scan_history", ["/scan"])
      refute Info.allowed?("/scan", ["/products"])
    end

    test "with no access control declared, everything declared is offered" do
      assert Info.allowed_routes(scope([]), Bare) == :all
      assert [%{group: nil, entries: [%{path: "/anything"}]}] = Info.sections(scope([]), Bare)
    end
  end

  describe "an icon the host draws itself" do
    test "a string names a heroicon" do
      assert render_component(&AshQuick.Components.nav_icon/1,
               icon: "hero-cube-solid",
               class: "w-4"
             ) =~ "hero-cube-solid"
    end

    test "a {module, function} renders whatever that component renders" do
      html =
        render_component(&AshQuick.Components.nav_icon/1,
          icon: {Icons, :brand},
          class: "w-4"
        )

      assert html =~ ~s|data-testid="hand-drawn"|
      assert html =~ ~s|class="w-4"|
    end

    test "so does a function, which is handed the class the rendering wants" do
      html =
        render_component(&AshQuick.Components.nav_icon/1,
          icon: &Icons.brand/1,
          class: "w-12"
        )

      assert html =~ ~s|class="w-12"|
    end

    test "an entry with no icon renders nothing rather than a placeholder" do
      assert render_component(&AshQuick.Components.nav_icon/1, icon: nil, class: "w-4") == ""
    end
  end

  defp entry(nav, router, path) do
    nav |> Info.entries(router) |> Enum.find(&(&1.path == path))
  end
end
