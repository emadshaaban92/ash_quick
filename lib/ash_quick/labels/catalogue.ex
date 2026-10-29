defmodule AshQuick.Labels.Catalogue do
  @moduledoc false
  # Every label a QuickView draws, in English, read while it compiles so
  # `AshQuick.Labels.Gettext` can give it a `gettext` call for each, the
  # msgid the `:label_translator` is handed. They are read the way the pages
  # draw them, through `AshQuick.Labels` with the translator held off
  # (`AshQuick.Labels.english/1`):
  #
  #   * its titles, and the labels of its list, details and export fields,
  #     a `label:` or the humanized name;
  #   * the labels the host writes elsewhere in its options: a saved
  #     filter's, the `new_action_label` and the bulk menu's, an item's
  #     `title` or a named action's;
  #   * its resource, and every resource a field reaches through a
  #     relationship or an embedded attribute: its public actions, every
  #     action's inputs (following an embedded resource or a managed
  #     relationship into the form it opens), its public fields as a filter or
  #     a flashed error names them, and the values of an enum or a `one_of`
  #     atom.
  #
  # It reads more than any one reader is shown, a field a policy hides or an
  # action nobody holds, since a missing label shows in English and an extra
  # entry costs a translator one line. What it cannot read: the value of an
  # `:atom` with no `one_of`, which is data rather than a name the resource
  # states, a bulk menu a function returns, which is only known once there is
  # a socket, and the labels a custom template draws itself.

  alias AshQuick.Labels
  alias AshQuick.LiveView.EnumOptions
  alias AshQuick.LiveView.Utils

  @doc "Every label a QuickView with these resolved `options` can draw, sorted."
  def labels(options) do
    Labels.english(fn -> options_labels(options) end)
  end

  defp options_labels(options) do
    resource = options.resource
    fields = options.list_fields ++ options.details_fields ++ options.export_fields

    resources =
      fields
      |> Enum.flat_map(&path_resources(resource, &1.path))
      |> then(&[resource | &1])
      |> Enum.reduce(MapSet.new(), &reachable/2)

    labels =
      [Labels.plural(resource), Labels.resource(resource)] ++
        Enum.map(fields, &Labels.field/1) ++
        written_labels(options) ++
        Enum.flat_map(resources, &resource_labels/1)

    labels
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # The labels the host writes outside its fields.
  defp written_labels(options) do
    filters = for %{"label" => label} <- options.filters, do: label
    [options.new_action_label | filters] ++ bulk_labels(options.bulk_actions)
  end

  defp bulk_labels(items) when is_list(items) do
    Enum.map(items, fn
      %{title: title} -> title
      name when is_atom(name) and name not in [nil, false] -> Labels.name(name)
      _item -> nil
    end)
  end

  defp bulk_labels(_function), do: []

  # The resources a field's path walks through to its value.
  defp path_resources(resource, path) when is_atom(path) do
    resource |> field_resource(path) |> List.wrap()
  end

  defp path_resources(resource, [{name, nested}]) do
    case field_resource(resource, name) do
      nil -> []
      destination -> [destination | path_resources(destination, nested)]
    end
  end

  defp path_resources(_resource, _path), do: []

  # The resource a path steps into at `name`, as `field_value` resolves it:
  # a relationship's destination, or the embedded resource an attribute or a
  # calculation holds.
  defp field_resource(resource, name) do
    case Ash.Resource.Info.field(resource, name) do
      %{destination: destination} -> destination
      %{type: type} -> embedded_resource(type)
      nil -> nil
    end
  end

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

  # `{action, field}` for every input an action's form draws: whatever
  # `Utils.action_fields/2` hands the forms, which is nothing for an action
  # without one.
  defp form_inputs(resource) do
    for %{name: action} <- Ash.Resource.Info.public_actions(resource),
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
end
