defmodule AshQuick.LiveView.QuickField do
  @moduledoc """
  A field on a QuickView page: what a `:fields` entry under `:list` or
  `:details` is normalized to before it is rendered.

  Its struct is internal. What a host reaches for here is `data_field/1`, the
  name the details page gives each of its rows, and `resolve_value/2`, the
  value a widget is handed.
  """
  alias AshQuick.LiveView.Utils

  defstruct [:path, :label, :widget, :data_field]

  @doc false
  def normalize(spec) do
    field = build(spec)
    %{field | data_field: path_name(field.path)}
  end

  defp build(field) when is_atom(field) do
    %__MODULE__{path: field, label: Utils.humanize(field)}
  end

  defp build([{_relationship, _nested}] = path) do
    %__MODULE__{path: path, label: label_from_path(path)}
  end

  defp build({path, label}) when is_binary(label) do
    %__MODULE__{path: normalize_path(path), label: label}
  end

  defp build({path, opts}) when is_atom(path) and is_list(opts) do
    if Keyword.keyword?(opts) do
      %__MODULE__{
        path: path,
        label: Keyword.get_lazy(opts, :label, fn -> Utils.humanize(path) end),
        widget: Keyword.get(opts, :widget)
      }
    else
      %__MODULE__{path: [{path, opts}], label: Utils.humanize(path)}
    end
  end

  defp build({[{_, _}] = path, opts}) when is_list(opts) do
    if Keyword.keyword?(opts) do
      %__MODULE__{
        path: path,
        label: Keyword.get_lazy(opts, :label, fn -> label_from_path(path) end),
        widget: Keyword.get(opts, :widget)
      }
    else
      %__MODULE__{path: path, label: label_from_path(path)}
    end
  end

  @doc false
  # Whether `rest`, the part of a field path past a relationship onto
  # `destination`, names the related record itself: nothing more (the field
  # stops at the relationship), or the destination's display label. The one
  # rule both the details query, which loads the hint of every record a field
  # names, and the details page, which links them, ask.
  def names_record?(destination, rest) do
    if Ash.Resource.Info.resource?(destination) and
         not Ash.Resource.Info.embedded?(destination) and
         AshQuick in Spark.extensions(destination) do
      label = AshQuick.Info.display_label(destination)
      rest in [nil, [], label, [label]]
    else
      false
    end
  end

  @doc false
  # Each record `path` names on a `resource` record, as the relationships that
  # reach it and its resource, at any depth: `:store` and `[store: :name]`
  # name a store, `[product: [brand: :name]]` a brand.
  def named_records(resource, path), do: named_records(resource, path, [])

  defp named_records(resource, name, chain) when is_atom(name),
    do: named_records(resource, [{name, nil}], chain)

  defp named_records(resource, [{name, rest}], chain) when is_atom(name) do
    case Ash.Resource.Info.relationship(resource, name) do
      %{destination: destination} ->
        if names_record?(destination, rest),
          do: [{chain ++ [name], destination}],
          else: named_records(destination, rest, chain ++ [name])

      nil ->
        []
    end
  end

  defp named_records(_resource, _path, _chain), do: []

  @doc """
  The value a widget is handed for `path` on `record`.

  A relationship path walks through a related record that may not be there: an
  empty nullable `belongs_to` reads as `nil`, and so does everything past it.
  The `nil` clause comes first because `nil` is itself an atom, so the
  `is_atom/1` clause would otherwise take it and `Map.get/2` on `nil` raises.
  A related record a policy hides is passed on as it is, for the same reason a
  missing one reads as `nil`: there is nothing past it to read.
  """
  def resolve_value(nil, _path), do: nil
  def resolve_value(%Ash.ForbiddenField{} = forbidden, _path), do: forbidden
  def resolve_value(record, path) when is_atom(path), do: Map.get(record, path)

  def resolve_value(record, [{relationship, nested}]) do
    record |> Map.get(relationship) |> resolve_value(nested)
  end

  defp normalize_path(path) when is_atom(path), do: path
  defp normalize_path([{_relationship, _nested}] = path), do: path

  @doc """
  The name of a field's path, as the details page puts it on the field's row in
  a `data-field` attribute.

  Takes a field as written under `:fields`, label and options included, and
  reads it as the details page does. A relationship path joins every segment
  with `.`:

      iex> AshQuick.LiveView.QuickField.data_field(:licence_holder_name)
      "licence_holder_name"

      iex> AshQuick.LiveView.QuickField.data_field([vehicle: :chassis_number])
      "vehicle.chassis_number"

      iex> AshQuick.LiveView.QuickField.data_field([vehicle: [owner: :name]])
      "vehicle.owner.name"

      iex> AshQuick.LiveView.QuickField.data_field({:code, label: "Reference"})
      "code"

  The name comes from the path alone, so it does not move when a label is
  reworded or translated. It is not unique on a page — one field can be listed
  twice — which is why it is an attribute and not an `id`.

  A custom details template that draws its own rows can put the same attribute
  on them, so a test reads both pages the same way:

      <div data-field={AshQuick.LiveView.QuickField.data_field(:licence_holder_name)}>
  """
  def data_field(%__MODULE__{data_field: name}) when is_binary(name), do: name
  def data_field(%__MODULE__{path: path}), do: path_name(path)
  def data_field(spec), do: normalize(spec).data_field

  defp path_name(path), do: path |> segments() |> Enum.join(".")

  # `[owner: []]` renders the related record itself, so its row is `"owner"`.
  defp segments([]), do: []
  defp segments(field) when is_atom(field), do: [Atom.to_string(field)]
  defp segments([nested]), do: segments(nested)
  defp segments({relationship, nested}), do: [Atom.to_string(relationship) | segments(nested)]

  defp label_from_path([{_relationship, nested}]) when is_atom(nested) do
    Utils.humanize(nested)
  end

  defp label_from_path([{relationship, _nested}]) do
    Utils.humanize(relationship)
  end
end
