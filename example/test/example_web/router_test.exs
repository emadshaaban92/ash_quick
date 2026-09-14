defmodule ExampleWeb.RouterTest do
  @moduledoc """
  This application's four route artifacts held to each other: the router, the
  nav, the access control and the roles.

  What `quick_view/3` produces and refuses is the library's, checked against the
  macro there. What cannot travel with it is any of this — the library cannot
  know which routes this app meant to grant, which paths it meant to render, or
  which of its QuickViews someone routed by hand. Each failure below is a page
  whose links are all broken, a role with no link that leads anywhere, or a
  tile missing from the apps grid, and none of them raises at runtime.
  """
  use ExUnit.Case, async: true

  alias AshQuick.Nav.Info
  alias ExampleWeb.AccessControl

  # The apps grid is the home page, so a tile leading back to it says nothing.
  @tile_less_routes ~w(/)

  describe "every QuickView in the application is routed through the macro" do
    setup do
      routes =
        ExampleWeb.Router
        |> Phoenix.Router.routes()
        |> Enum.filter(&(&1.plug == Phoenix.LiveView.Plug))

      %{routes: routes}
    end

    test "a route to a QuickView carries the base path it was declared with", %{routes: routes} do
      undeclared =
        for route <- routes,
            quick_view?(route),
            not match?(%{ash_quick: %{base_path: _}}, route.metadata),
            do: route.path

      assert undeclared == [],
             """
             These QuickViews are routed by a plain `live/3`, so they have no base \
             path to read at request time and every link they build is wrong. \
             Declare them with `AshQuick.LiveView.Router.quick_view/3`:

             #{Enum.join(undeclared, "\n")}
             """

      for route <- routes, quick_view?(route) do
        base_path = route.metadata.ash_quick.base_path

        assert route.path == base_path or String.starts_with?(route.path, base_path <> "/"),
               "#{route.path} is served under a base path of #{base_path}"
      end
    end

    test "no route to anything else carries one", %{routes: routes} do
      mislabelled =
        for route <- routes,
            Map.has_key?(route.metadata, :ash_quick),
            not quick_view?(route),
            do: route.path

      assert mislabelled == [],
             "routed as QuickViews but are not: #{Enum.join(mislabelled, ", ")}"
    end
  end

  describe "the nav, the router and access control reconcile" do
    setup do
      routed = ExampleWeb.Router |> Phoenix.Router.routes() |> MapSet.new(& &1.path)

      grouped = ExampleWeb.Nav |> Info.groups() |> Enum.flat_map(& &1.paths) |> Enum.uniq()

      declared =
        ExampleWeb.Nav
        |> Info.declared_entries()
        |> Enum.map(& &1.path)
        |> Enum.concat(grouped)
        |> Enum.uniq()

      %{
        routed: routed,
        declared: declared,
        grouped: grouped,
        entries: Enum.map(Info.entries(ExampleWeb.Nav, ExampleWeb.Router), & &1.path),
        granted: granted_routes()
      }
    end

    test "every path the nav declares is one the router serves",
         %{routed: routed, declared: declared} do
      unrouted = Enum.reject(declared, &MapSet.member?(routed, &1))

      assert unrouted == [],
             """
             ExampleWeb.Nav declares these paths and ExampleWeb.Router serves none \
             of them. Each renders as a sidebar link or a grid tile that 404s:

             #{Enum.join(unrouted, "\n")}
             """
    end

    # Against the resolved entries rather than the declarations, because those
    # are what render: a QuickView the router serves is an entry whether or not
    # anything declared it, and a path a group names but nothing is an entry for
    # is a reference to nothing, which the sidebar drops silently.
    test "every route a role is granted has an entry that renders it",
         %{entries: entries, granted: granted} do
      uncovered = Enum.reject(granted, &Info.allowed?(&1, entries))

      assert uncovered == [],
             """
             ExampleWeb.AccessControl grants these routes and no entry in \
             ExampleWeb.Nav renders any of them, so the roles holding them have \
             no link that leads there:

             #{Enum.join(uncovered, "\n")}
             """
    end

    test "every route a role is granted sits in a group, so the apps grid has a tile for it",
         %{grouped: grouped, granted: granted} do
      tile_less =
        Enum.reject(granted, &(Info.allowed?(&1, grouped) or &1 in @tile_less_routes))

      assert tile_less == [],
             """
             ExampleWeb.AccessControl grants these routes and no `group` in \
             ExampleWeb.Nav names them, so they have a sidebar link but no tile \
             in the apps grid:

             #{Enum.join(tile_less, "\n")}
             """
    end

    test "every entry the nav offers is one some role can reach", %{granted: granted} do
      unreachable =
        ExampleWeb.Nav
        |> Info.entries(ExampleWeb.Router)
        |> Enum.map(& &1.path)
        |> Enum.reject(&Info.allowed?(&1, granted))

      assert unreachable == [],
             """
             ExampleWeb.Nav offers these paths and no role in \
             ExampleWeb.AccessControl can reach any of them, so they render for \
             nobody:

             #{Enum.join(unreachable, "\n")}
             """
    end
  end

  # Taken from the role list on the resource rather than from a copy of it here,
  # so a role added to `Example.Accounts.User` and nowhere else fails this.
  defp granted_routes do
    Example.Accounts.User
    |> Ash.Resource.Info.attribute(:role)
    |> Map.fetch!(:constraints)
    |> Keyword.fetch!(:one_of)
    |> Enum.flat_map(&AccessControl.routes_for_role/1)
    |> Enum.concat(
      AccessControl.routes_for(%Example.Scope{
        current_user: %Example.Accounts.User{role: :viewer, active: true}
      })
    )
    |> Enum.uniq()
  end

  # `Code.ensure_loaded?` first: `function_exported?/3` answers false for a
  # module that has not been loaded yet, and after a partial recompile the
  # router is loaded while the views it names are not — which would read as
  # "this QuickView is not one" and fail for the wrong reason.
  defp quick_view?(route) do
    view = elem(route.metadata.phoenix_live_view, 0)
    Code.ensure_loaded?(view) and function_exported?(view, :__ash_quick_options__, 0)
  end
end
