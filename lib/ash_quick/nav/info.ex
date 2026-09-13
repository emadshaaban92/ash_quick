defmodule AshQuick.Nav.Info do
  @moduledoc """
  Resolves a declared nav against the routes a router actually serves, and
  filters the result to what a scope can reach.

  `sections/1` is what the sidebar and the grid both render. Everything below
  it is exposed so the same registry can be asserted against the router and
  against the host's access control in a test.
  """

  alias AshQuick.Config
  alias AshQuick.LiveView.Utils
  alias AshQuick.Nav.Entry
  alias AshQuick.Nav.Group
  alias AshQuick.Nav.Section

  @default_icon "hero-rectangle-stack-solid"

  @doc """
  The nav `scope` can reach, in declaration order.

  Groups render in the order they were declared, holding only the entries the
  scope is allowed to navigate to; a group left with none is dropped. Entries
  belonging to no group come first, in one section with no group — the sidebar
  renders them without a heading and the grid skips them.
  """
  def sections(scope), do: sections(scope, Config.nav())

  def sections(scope, nav), do: sections(scope, nav, router(nav))

  def sections(scope, nav, router) do
    allowed = allowed_routes(scope, nav)

    # Resolving is what costs — a label the declaration left out is humanized
    # from the resource. A path is enough to know the scope cannot reach it, so
    # the ones it cannot are dropped before any of them are resolved.
    entries =
      nav
      |> unresolved(router)
      |> Enum.filter(fn {entry, _resource} -> allowed?(entry.path, allowed) end)
      |> Enum.map(fn {entry, resource} -> resolve(entry, resource) end)

    by_path = Map.new(entries, &{&1.path, &1})
    groups = groups(nav)
    grouped = MapSet.new(Enum.flat_map(groups, & &1.paths))

    ungrouped_section(Enum.reject(entries, &MapSet.member?(grouped, &1.path))) ++
      group_sections(groups, by_path)
  end

  @doc """
  Every entry, reachable or not: the declared ones first, then the QuickViews
  the router serves that nothing declared.

  Each comes back resolved — a label and an icon, whether or not the
  declaration supplied them.
  """
  def entries(nav, router) do
    nav
    |> unresolved(router)
    |> Enum.map(fn {entry, resource} -> resolve(entry, resource) end)
  end

  @doc "The router `nav` declared its QuickViews are discovered from, or `nil`."
  def router(nav), do: persisted(nav, :router)

  @doc "The `AshQuick.AccessControl` `nav` declared it is filtered through, or `nil`."
  def access_control(nav), do: persisted(nav, :access_control)

  @doc "The groups the nav declares, in declaration order."
  def groups(nav), do: nav |> entities() |> Enum.filter(&is_struct(&1, Group))

  @doc "The entries the nav declares, before their labels and icons are resolved."
  def declared_entries(nav), do: nav |> entities() |> Enum.filter(&is_struct(&1, Entry))

  @doc """
  The base path of every QuickView `router` serves, paired with its resource.

  Read off the route metadata `AshQuick.LiveView.Router.quick_view/3` writes,
  so the four routes a QuickView answers collapse onto the one path it is
  reached at without any path parsing, and a path the router does not serve
  cannot appear.
  """
  def discovered(nil), do: []

  def discovered(router) do
    router
    |> Phoenix.Router.routes()
    |> Enum.flat_map(fn
      %{metadata: %{ash_quick: %{base_path: path}}} = route -> [{path, resource(route)}]
      _route -> []
    end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  @doc """
  Whether `path` is covered by `routes` — equal to one, or directly under it.

  The rule the whole registry matches on, and the same one a host's route gate
  applies on navigation: an entry for `/products` is reachable by a scope
  granted `/products`, and `/scan/history` by one granted `/scan`.
  """
  def allowed?(_path, :all), do: true

  def allowed?(path, routes) when is_list(routes) do
    Enum.any?(routes, &(path == &1 or String.starts_with?(path, &1 <> "/")))
  end

  @doc """
  The routes `scope` may navigate to, or `:all` when `nav` declares no access
  control.
  """
  def allowed_routes(scope, nav) do
    case access_control(nav) do
      nil -> :all
      module -> module.routes_for(scope)
    end
  end

  defp entities(nil), do: []
  defp entities(nav), do: Spark.Dsl.Extension.get_entities(nav, [:nav])

  defp persisted(nil, _key), do: nil
  defp persisted(nav, key), do: Spark.Dsl.Extension.get_persisted(nav, key)

  defp ungrouped_section([]), do: []
  defp ungrouped_section(entries), do: [%Section{group: nil, entries: entries}]

  defp group_sections(groups, by_path) do
    groups
    |> Enum.map(
      &%Section{
        group: &1,
        entries: Enum.flat_map(&1.paths, fn path -> List.wrap(by_path[path]) end)
      }
    )
    |> Enum.reject(&(&1.entries == []))
  end

  # Every entry paired with the resource its label may be derived from, in the
  # order they render: declared first, then the QuickViews nothing declared.
  defp unresolved(nav, router) do
    discovered = discovered(router)
    resources = Map.new(discovered)
    declared = declared_entries(nav)
    declared_paths = MapSet.new(declared, & &1.path)

    Enum.map(declared, &{&1, Map.get(resources, &1.path)}) ++
      for {path, resource} <- discovered,
          not MapSet.member?(declared_paths, path),
          do: {%Entry{path: path}, resource}
  end

  defp resolve(%Entry{} = entry, resource) do
    %{
      entry
      | resource: resource,
        label: entry.label || derived_label(entry.path, resource),
        icon: entry.icon || @default_icon
    }
  end

  # A resource names itself better than its path does — but only when it has a
  # plural name, and only when the path is one it is the subject of. A path
  # serving a resource under another name (a profile page over a user) states
  # its own label rather than inheriting one that is wrong.
  defp derived_label(path, nil), do: path_label(path)

  defp derived_label(path, resource) do
    case Ash.Resource.Info.plural_name(resource) do
      nil -> path_label(path)
      plural -> Utils.humanize(plural)
    end
  end

  defp path_label(path) do
    case String.split(path, "/", trim: true) do
      [] -> path
      segments -> segments |> List.last() |> Utils.humanize()
    end
  end

  # A route reached through a plain `live/3` has no options to read, and a
  # module the router names may not be loaded yet in a lazily-loading
  # environment.
  defp resource(route) do
    view = elem(route.metadata.phoenix_live_view, 0)

    if Code.ensure_loaded?(view) and function_exported?(view, :__ash_quick_options__, 0) do
      view.__ash_quick_options__().resource
    end
  end
end
