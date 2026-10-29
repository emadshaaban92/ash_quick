defmodule AshQuick.Labels.Catalogue do
  @moduledoc """
  Every label AshQuick draws for an application, in English, as
  `mix ash_quick.gen.gettext` writes them out for translating.

  A label is not a `gettext` call, so `mix gettext.extract` cannot find it.
  These are read the way the pages draw them, through `AshQuick.Labels` with
  the `:label_translator` held off (`AshQuick.Labels.english/1`), so each one
  is the msgid the translator is handed. They come from:

    * the nav: every entry and every group;
    * each QuickView the nav's router serves: its titles, its list, details
      and export fields, its saved filters, its `new_action_label`, and the
      titles of the custom items in a `bulk_actions` list;
    * the resource of each, and every resource a field reaches through a
      relationship: its public actions, each create's and update's inputs
      (following an embedded resource or a managed relationship into the
      form it opens), its public fields as a filter or a flashed error names
      them, and the values of an enum or a `one_of` atom.

  It reads more than any one reader is shown, a field a policy hides or an
  action nobody holds, since a catalogue missing a label shows it in English
  and an extra entry costs a translator one line. What it cannot read: the
  titles a `bulk_actions` function returns, which need a socket, and the
  labels a custom template draws itself.
  """

  alias AshQuick.Config
  alias AshQuick.Labels
  alias AshQuick.LiveView.EnumOptions
  alias AshQuick.LiveView.Utils
  alias AshQuick.Nav.Info

  @doc """
  `{label, sources}` for every label `nav` and the QuickViews its router
  serves can draw, sorted by label. A source is the file of the nav or the
  QuickView that draws it, relative to the working directory.
  """
  def labels(nav \\ Config.nav()) do
    Labels.english(fn ->
      router = Info.router(nav)

      (nav_labels(nav, router) ++ Enum.flat_map(quick_views(router), &view_labels/1))
      |> Enum.filter(fn {label, _source} -> is_binary(label) and label != "" end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {label, sources} ->
        {label, sources |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()}
      end)
      |> Enum.sort()
    end)
  end

  defp nav_labels(nil, _router), do: []

  defp nav_labels(nav, router) do
    source = source(nav)

    Enum.map(Info.entries(nav, router), &{&1.label, source}) ++
      Enum.map(Info.groups(nav), &{&1.label, source})
  end

  defp quick_views(nil), do: []

  defp quick_views(router) do
    router
    |> Phoenix.Router.routes()
    |> Enum.flat_map(fn
      %{metadata: %{ash_quick: _, phoenix_live_view: {view, _, _, _}}} -> [view]
      _route -> []
    end)
    |> Enum.uniq()
    |> Enum.filter(
      &(Code.ensure_loaded?(&1) and function_exported?(&1, :__ash_quick_options__, 0))
    )
  end

  defp view_labels(view) do
    options = view.__ash_quick_options__()
    resource = options.resource
    fields = options.list_fields ++ options.details_fields ++ options.export_fields

    resources =
      fields
      |> Enum.flat_map(&path_resources(resource, &1.path))
      |> then(&[resource | &1])
      |> Enum.reduce(MapSet.new(), &reachable/2)

    labels =
      [Labels.plural(resource), Labels.resource(resource), options.new_action_label] ++
        Enum.map(fields, &Labels.field/1) ++
        for(%{"label" => label} <- List.wrap(options.filters), do: label) ++
        bulk_titles(options.bulk_actions) ++
        Enum.flat_map(resources, &resource_labels/1)

    source = source(view)
    Enum.map(labels, &{&1, source})
  end

  defp bulk_titles(items) when is_list(items), do: for(%{title: title} <- items, do: title)
  defp bulk_titles(_none_or_function), do: []

  # The resources a field's path walks through to its value.
  defp path_resources(resource, path) when is_atom(path) do
    case Ash.Resource.Info.relationship(resource, path) do
      nil -> []
      relationship -> [relationship.destination]
    end
  end

  defp path_resources(resource, [{name, nested}]) do
    case Ash.Resource.Info.relationship(resource, name) do
      nil ->
        []

      relationship ->
        [relationship.destination | path_resources(relationship.destination, nested)]
    end
  end

  defp path_resources(_resource, _path), do: []

  # `resource` and every resource one of its forms opens a form for.
  defp reachable(resource, seen) do
    if MapSet.member?(seen, resource) do
      seen
    else
      resource
      |> form_inputs()
      |> Enum.flat_map(fn {action, field} -> nested_resources(resource, action, field) end)
      |> Enum.reduce(MapSet.put(seen, resource), &reachable/2)
    end
  end

  defp resource_labels(resource) do
    actions = Ash.Resource.Info.public_actions(resource)
    inputs = resource |> form_inputs() |> Enum.map(&elem(&1, 1))

    fields =
      Ash.Resource.Info.public_attributes(resource) ++
        Ash.Resource.Info.public_calculations(resource) ++
        Ash.Resource.Info.public_aggregates(resource) ++ inputs

    for(%{type: type, name: name} <- actions, type in [:create, :update, :destroy], do: name)
    |> Enum.concat(Enum.map(fields, & &1.name))
    |> Enum.map(&Labels.name/1)
    |> Enum.concat(Enum.flat_map(fields, &enum_labels/1))
  end

  defp enum_labels(%{destination: _relationship}), do: []

  defp enum_labels(field) do
    if EnumOptions.kind(field),
      do: field |> EnumOptions.options() |> Enum.map(&elem(&1, 0)),
      else: []
  end

  # `{action, field}` for every input a create's or an update's form draws.
  defp form_inputs(resource) do
    for %{type: type, name: action} <- Ash.Resource.Info.public_actions(resource),
        type in [:create, :update],
        field <- Utils.action_fields(resource, action),
        do: {action, Utils.argument_to_relationship(field, resource, action)}
  end

  defp nested_resources(_resource, _action, %{destination: _relationship}), do: []

  defp nested_resources(resource, action, field) do
    managed =
      with name when not is_nil(name) <- Utils.managed_relationship(resource, action, field.name),
           %{destination: destination} <- Ash.Resource.Info.relationship(resource, name),
           do: destination

    Enum.reject([embedded_resource(field.type), managed], &is_nil/1)
  end

  defp embedded_resource({:array, type}), do: embedded_resource(type)

  defp embedded_resource(type) when is_atom(type),
    do: if(Ash.Type.embedded_type?(type), do: type)

  defp embedded_resource(_type), do: nil

  defp source(module) do
    case module.module_info(:compile)[:source] do
      nil -> nil
      source -> source |> to_string() |> Path.relative_to_cwd()
    end
  end
end
