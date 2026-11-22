defmodule AshQuick.LiveView.FormRecords do
  @moduledoc false
  # The records a relationship input of a form (`BelongsToInput`,
  # `HasManyInput`) offers and holds, as `AshQuick.LiveView.Picker` options:
  # read through the destination's lookup action with the reader's scope.
  #
  # An option is `%{value:, label:, hint:}`, its label the record's display
  # name and its hint the display hint, and its value the field `key` names,
  # as text. `current` is what the form's own record holds of the
  # relationship, loaded with it.
  require Ash.Query
  require Logger

  alias AshQuick.LiveView.Utils

  @doc """
  The records `search` matches, a page of them, or `{options, :more}` when
  the page is not all. Records the relationship's filters leave out, and
  inactive ones, are not offered. With nothing typed, `current` leads.
  """
  def search(relationship, key, search, scope, current) do
    relationship
    |> query(key, search, scope)
    |> Utils.filter_inactive()
    |> add_filters(relationship.filters)
    |> Ash.Query.page(count: false)
    |> read(relationship)
    |> case do
      {records, more?} ->
        leading = if is_nil(search), do: current, else: []

        options =
          (leading ++ records)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq_by(&Map.fetch!(&1, key))
          |> Enum.map(&option(&1, key))

        if more?, do: {options, :more}, else: options
    end
  end

  @doc """
  The options for `values`, the keys the field holds, read in as few
  queries as the lookup action's `max_page_size` allows.
  Unlike a search, inactive records and those the relationship's filters
  leave out are named too: the field holds them. A key the reader may not
  read, or that names nothing, is named from `current` when the form's
  record holds it, and is otherwise left out, for the picker to keep as
  unavailable.
  """
  def resolve(relationship, key, values, scope, current) do
    attribute = Ash.Resource.Info.field(relationship.destination, key)

    keys =
      for value <- values,
          {:ok, cast} <- [cast(attribute, value)],
          not is_nil(cast),
          uniq: true,
          do: cast

    # In pages the lookup action allows: Ash clamps a larger limit to its
    # `max_page_size`, which would leave the keys past it unnamed.
    found =
      keys
      |> Enum.chunk_every(max_page_size(relationship))
      |> Enum.flat_map(fn chunk ->
        {records, _more?} =
          relationship
          |> query(key, nil, scope)
          |> Ash.Query.filter(^Ash.Expr.ref(key) in ^chunk)
          |> Ash.Query.page(limit: length(chunk), count: false)
          |> read(relationship)

        records
      end)

    # What was read wins over what the form's record holds, since it carries
    # the label and hint loaded for the reader.
    current
    |> Enum.reject(&is_nil/1)
    |> Enum.concat(found)
    |> Enum.map(&option(&1, key))
  end

  defp max_page_size(relationship) do
    action =
      Ash.Resource.Info.action(relationship.destination, Utils.lookup_action!(relationship))

    case action do
      %{pagination: %{max_page_size: max}} when is_integer(max) and max > 0 -> max
      _no_cap -> 250
    end
  end

  defp cast(%{type: type, constraints: constraints}, value),
    do: Ash.Type.cast_input(type, value, constraints)

  defp cast(nil, value), do: {:ok, value}

  defp query(relationship, key, search, scope) do
    relationship.destination
    |> Ash.Query.for_read(
      Utils.lookup_action!(relationship),
      Utils.lookup_input(relationship.destination, search),
      scope: scope
    )
    |> Ash.Query.select(key)
    |> Utils.load_display_label()
    |> Utils.load_display_hint()
  end

  defp add_filters(query, []), do: query

  defp add_filters(query, [%Ash.Resource.Dsl.Filter{filter: filter} | rest]),
    do: query |> Ash.Query.filter(^filter) |> add_filters(rest)

  # A read the destination refuses offers nothing and is logged: the visitor
  # sees an empty list, or what the field holds named as unavailable.
  defp read(query, relationship) do
    case Ash.read(query) do
      {:ok, %{results: records} = page} ->
        {records, Map.get(page, :more?, false) == true}

      {:ok, records} when is_list(records) ->
        {records, false}

      {:error, error} ->
        Logger.warning(fn ->
          "AshQuick could not read #{inspect(query.resource)} for the form input of " <>
            "#{inspect(relationship.source)}.#{relationship.name}, which offers and " <>
            "names none of its records:\n\n" <>
            Exception.message(Ash.Error.to_error_class(error))
        end)

        {[], false}
    end
  end

  defp option(record, key) do
    %{name: name, hint: hint, value: value} = Utils.to_option(record, key)
    %{value: to_string(value), label: name, hint: hint && to_string(hint)}
  end
end
