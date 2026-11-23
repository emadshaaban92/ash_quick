defmodule AshQuick.LiveView.FilterRecords do
  @moduledoc false
  # The records a record row of the list's filter picks from, and those it
  # holds, as `AshQuick.LiveView.Picker` options: read through the
  # destination's lookup action with the reader's scope, so a record they
  # may not read is neither offered nor named. An option is
  # `%{value:, label:, hint:}`, its label the record's display name, its hint
  # the display hint, and its value its primary key as the row holds it and
  # the URL carries it, a string.
  use Gettext, backend: AshQuick.Gettext
  require Ash.Query
  require Logger

  alias AshQuick.LiveView.CustomFilter
  alias AshQuick.LiveView.FilterField
  alias AshQuick.LiveView.URLParams
  alias AshQuick.LiveView.Utils

  # A destination can hold thousands of records, so the picker offers the
  # first few a search matches, and the search narrows them.
  @limit 20

  @doc """
  The records of `field`'s destination `search` matches, the first #{@limit},
  or `{options, :more}` when there are more.
  """
  def search(%FilterField{resource: resource, field: key}, search, scope) do
    {options, more?} =
      resource
      |> query(key, search, scope)
      |> Ash.Query.page(limit: @limit, count: false)
      |> read(key)

    if more?, do: {options, :more}, else: options
  end

  @doc """
  The options for `ids`, the values a row's picker holds, as `held/3` names
  them, each carrying the id it was asked for.
  """
  def resolve(%FilterField{} = field, ids, scope),
    do: for({id, option} <- held(field, ids, scope), do: %{option | value: id})

  @doc """
  The option for each of `ids`, by id: the record's, or a placeholder for
  one that will not cast, is gone, or the reader may not read, which names
  nothing of it. Read in one query.
  """
  def held(%FilterField{}, [], _scope), do: %{}

  def held(%FilterField{resource: resource, field: key}, ids, scope) do
    cast =
      for id <- ids,
          {:ok, value} <- [CustomFilter.cast_value(key, id)],
          not is_nil(value),
          into: %{},
          do: {id, to_string(value)}

    found =
      case cast |> Map.values() |> Enum.uniq() do
        [] ->
          %{}

        values ->
          resource
          |> query(key, nil, scope)
          |> Ash.Query.filter(^Ash.Expr.ref(key.name) in ^values)
          |> Ash.Query.page(limit: length(values), count: false)
          |> read(key)
          |> elem(0)
          |> Map.new(&{&1.value, &1})
      end

    Map.new(ids, &{&1, Map.get(found, cast[&1]) || unavailable(&1)})
  end

  @doc """
  The options naming the records each record row of `params`' applied filter
  holds, by field name and id, as `held/3` reads them: one query per field.
  Read where the list is read, so the list's chips run no query as they
  render.
  """
  def held_by_field(resource, %URLParams{custom_filter: %CustomFilter{} = filter} = params, scope) do
    fields = CustomFilter.fields_by_name(resource, params.filterable)

    filter
    |> CustomFilter.applied_leaves()
    |> Enum.flat_map(&held_ids(&1, fields[&1.field_name]))
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {field, ids} -> {field.name, held(field, Enum.uniq(ids), scope)} end)
  end

  def held_by_field(_resource, _params, _scope), do: %{}

  defp held_ids(%CustomFilter{operator: "in", value: value}, %FilterField{record?: true} = field),
    do: for(id <- List.wrap(value), is_binary(id) and id != "", do: {field, id})

  defp held_ids(_row, _field), do: []

  @doc """
  The option standing for a record the reader cannot be shown, which names
  nothing of it.
  """
  def unavailable(id), do: %{label: gettext("Unavailable record"), value: id, hint: nil}

  # Inactive records are offered too, though a relationship dropdown hides
  # them: a list is filtered by what its rows hold, and a row can hold a
  # record that has since been deactivated.
  defp query(resource, key, search, scope) do
    resource
    |> Ash.Query.for_read(
      AshQuick.Info.lookup_action(resource),
      Utils.lookup_input(resource, search),
      scope: scope
    )
    |> Ash.Query.select(key.name)
    # An aggregate label needing a tenant the reader has not got is skipped
    # rather than failing the read, and the record is named by its key, as a
    # list row's checkbox is.
    |> Utils.load_display_label()
    |> Utils.load_display_hint()
  end

  # The options read, and whether there are more past them. A read the
  # destination refuses offers nothing, as one it filters to nothing does,
  # and is logged: the visitor sees an empty picker, or a record they picked
  # named as unavailable, and nothing more.
  defp read(query, key) do
    case Ash.read(query) do
      {:ok, %{results: records} = page} ->
        {Enum.map(records, &option(&1, key)), Map.get(page, :more?, false) == true}

      {:ok, records} when is_list(records) ->
        {Enum.map(records, &option(&1, key)), false}

      {:error, error} ->
        Logger.warning(fn ->
          "AshQuick could not read #{inspect(query.resource)} for a record filter row, " <>
            "which offers and names none of its records:\n\n" <>
            Exception.message(Ash.Error.to_error_class(error))
        end)

        {[], false}
    end
  end

  defp option(record, key) do
    %{name: name, hint: hint, value: value} = Utils.to_option(record, key.name)
    %{value: to_string(value), label: name, hint: hint && to_string(hint)}
  end
end
