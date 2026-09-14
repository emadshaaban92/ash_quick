defmodule AshQuick.Check.Nav do
  @moduledoc false
  # The nav, the router and the access control held to each other.
  #
  # Three artifacts describing one route, and every way they can disagree is
  # silent: a nav path no route serves renders as a link that 404s, a granted
  # route no entry renders leaves the roles holding it with no way to get there,
  # and an entry no role can reach renders for nobody.
  #
  # Deliberately not here: a granted route that sits in no `group`. That is a
  # page with a sidebar link and no tile on the apps grid, which is a layout
  # decision far more often than a mistake — the home page is the grid, so a
  # tile leading back to it says nothing.
  #
  # The last three are statements about *some role*, and roles are the host's —
  # so they run only against an access control exporting `all_routes/0`, and are
  # reported as not run rather than passing when it does not.

  alias AshQuick.Check.Finding
  alias AshQuick.Nav.Info

  def run(nil, _router, _access_control),
    do: {[], [{:nav, "no nav is configured, so there is nothing to reconcile"}]}

  def run(_nav, nil, _access_control),
    do: {[], [{:nav, "the nav declares no router, so no path can be checked against one"}]}

  def run(nav, router, access_control) do
    routed = MapSet.new(Phoenix.Router.routes(router), & &1.path)
    grouped = nav |> Info.groups() |> Enum.flat_map(& &1.paths) |> Enum.uniq()

    declared =
      nav |> Info.declared_entries() |> Enum.map(& &1.path) |> Enum.concat(grouped) |> Enum.uniq()

    entries = nav |> Info.entries(router) |> Enum.map(& &1.path)

    {granted_findings, skipped} =
      case granted(access_control) do
        {:ok, granted} -> {granted(granted, routed, entries, nav, access_control), []}
        {:skip, reason} -> {[], [{:nav, reason}]}
      end

    {unrouted_nav_paths(declared, routed, nav, router) ++ granted_findings, skipped}
  end

  # A grant the router does not serve is reported once, as itself: it has no
  # entry either, and saying so twice buries the one fact that explains both.
  defp granted(granted, routed, entries, nav, access_control) do
    unrouted = unrouted_grants(granted, routed, access_control)
    live = granted -- Enum.map(unrouted, & &1.subject)

    unrouted ++
      linkless(live, entries, nav, access_control) ++
      unreachable(entries, granted, nav, access_control)
  end

  # A nav path is a link rendered verbatim, so it has to be a route served
  # verbatim — prefix matching is what a *grant* means, not what a link does.
  defp unrouted_nav_paths(declared, routed, nav, router) do
    for path <- declared, not MapSet.member?(routed, path) do
      %Finding{
        check: :unrouted_nav_path,
        subject: path,
        message: """
        #{inspect(nav)} declares #{path}, and #{inspect(router)} serves no such \
        route.

        It renders as a sidebar link or a grid tile that 404s. Route it, or \
        drop the `entry` and any `group` naming it.
        """
      }
    end
  end

  defp unrouted_grants(granted, routed, access_control) do
    routes = MapSet.to_list(routed)

    for path <- granted, not Enum.any?(routes, &under?(&1, path)) do
      %Finding{
        check: :unrouted_grant,
        subject: path,
        message: """
        #{inspect(access_control)} grants #{path}, and the router serves \
        nothing at or under it.

        The grant is dead — a leftover from a route that was renamed or \
        removed. It widens what every role holding it may reach the day \
        something is routed there again.
        """
      }
    end
  end

  # Against the resolved entries rather than the declarations, because those are
  # what render: a QuickView the router serves is an entry whether or not
  # anything declared it, and a path a group names but nothing is an entry for
  # is a reference to nothing, which the sidebar drops silently.
  defp linkless(granted, entries, nav, access_control) do
    for path <- granted, not Info.allowed?(path, entries) do
      %Finding{
        check: :linkless_route,
        subject: path,
        message: """
        #{inspect(access_control)} grants #{path}, and no entry in \
        #{inspect(nav)} renders it.

        Every role holding it can reach the page by typing the URL and by no \
        other means. Give it an `entry`, or stop granting it.
        """
      }
    end
  end

  defp unreachable(entries, granted, nav, access_control) do
    for path <- entries, not Info.allowed?(path, granted) do
      %Finding{
        check: :unreachable_entry,
        subject: path,
        message: """
        #{inspect(nav)} offers #{path}, and no role in \
        #{inspect(access_control)} can reach it.

        It renders for nobody. Either it is a page whose grant was forgotten — \
        in which case every role that should hold it is currently getting a 403 \
        at that URL — or the entry outlived the page.
        """
      }
    end
  end

  defp granted(nil), do: {:skip, "the nav declares no access control, so no route is granted"}

  defp granted(access_control) do
    if Code.ensure_loaded?(access_control) and function_exported?(access_control, :all_routes, 0) do
      {:ok, Enum.uniq(access_control.all_routes())}
    else
      {:skip,
       """
       #{inspect(access_control)} exports no `all_routes/0`, so the routes it \
       grants cannot be enumerated. Three checks did not run: a grant the \
       router does not serve, a granted route with no nav entry, and a nav \
       entry no role can reach. See `AshQuick.AccessControl`.\
       """}
    end
  end

  defp under?(path, base), do: path == base or String.starts_with?(path, base <> "/")
end
