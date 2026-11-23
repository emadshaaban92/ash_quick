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
  #
  # `narrowing` is what the QuickView's `adjust_form/2` put on the field
  # (`AshQuick.FormState.filter/3` and `lookup_args/3`): `%{filters:,
  # lookup_args:}`, or nil for none. Its filters go on top of the
  # relationship's own, and its arguments to the lookup action.
  require Ash.Query
  require Logger

  alias AshQuick.LiveView.Utils

  @doc """
  What `field`, an `AshQuick.FormState.Field` or nil, narrows its records
  by, or nil when it narrows nothing: a picker searches again when it
  changes.
  """
  def narrowing(%{filters: filters, lookup_args: args}) when filters != [] or args != %{},
    do: %{filters: filters, lookup_args: args}

  def narrowing(_field), do: nil

  @doc """
  The records `search` matches, a page of them, or `{options, :more}` when
  the page is not all. Records the relationship's filters leave out, and
  inactive ones, are not offered, nor those `narrowing` leaves out. With
  nothing typed, `current` leads, unless `narrowing` narrows the field: the
  save then checks what the record holds too, so it is offered only when
  the read finds it.
  """
  def search(relationship, key, search, scope, current, narrowing \\ nil) do
    relationship
    |> query(key, search, scope, narrowing)
    |> Utils.filter_inactive()
    |> add_filters(relationship.filters)
    |> add_filters(filters(narrowing))
    |> Ash.Query.page(count: false)
    |> read(relationship)
    |> case do
      {records, more?} ->
        leading = if is_nil(search) and not narrows?(narrowing), do: current, else: []

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
  unavailable. Only `narrowing`'s arguments are passed, which a lookup
  action may need: a value its filters leave out is named all the same.
  """
  def resolve(relationship, key, values, scope, current, narrowing \\ nil) do
    found =
      relationship
      |> query(key, nil, scope, narrowing)
      |> read_keys(relationship, key, values)

    # What was read wins over what the form's record holds, since it carries
    # the label and hint loaded for the reader.
    current
    |> Enum.reject(&is_nil/1)
    |> Enum.concat(found)
    |> Enum.map(&option(&1, key))
  end

  @doc """
  Which of `values`, the keys a field posts, the field does not offer: those
  the lookup action, the relationship's filters and `narrowing` leave out,
  and, of those not in `kept`, inactive ones too. `kept` are the keys the
  form's record already holds, which a picker offers whatever their state.
  Keys are compared as the destination's type compares them, so a
  `ci_string` key posted in another case is the record it names.

  With `created`, the `Utils.created_values/3` of a picker that adds what
  matches no record, a key no record holds is new, not refused: the action
  creates it. Only a record there is that the field leaves out is refused.
  Whether one is there takes a second read, made as the change will look it
  up: through its `read_action`, with the scope, and with none of the
  lookup action's filters or arguments, so a record the lookup action hides
  is still found, and refused.

  A read the destination refuses offers nothing, so every value is out.
  """
  def not_offered(relationship, key, values, scope, narrowing, kept, created \\ nil) do
    activation = AshQuick.Info.activation(relationship.destination)
    %{type: type} = attribute = Ash.Resource.Info.field(relationship.destination, key)
    cast = fn value -> cast_or_self(attribute, value) end

    query =
      relationship
      |> query(key, nil, scope, narrowing)
      |> add_filters(relationship.filters)
      |> add_filters(filters(narrowing))
      |> then(&if activation, do: Ash.Query.select(&1, [activation.attribute]), else: &1)

    kept = Enum.map(kept, cast)

    offered =
      for record <- read_keys(query, relationship, key, values),
          value = Map.fetch!(record, key),
          Enum.any?(kept, &Ash.Type.equal?(type, &1, value)) or active?(record, activation),
          do: value

    out =
      values
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq_by(&to_string/1)
      |> Enum.reject(fn value -> Enum.any?(offered, &Ash.Type.equal?(type, &1, cast.(value))) end)

    if created && out != [] do
      there = existing(relationship, created.read_action, key, Enum.map(out, cast), scope)
      Enum.filter(out, fn value -> Enum.any?(there, &Ash.Type.equal?(type, &1, cast.(value))) end)
    else
      out
    end
  end

  # The keys among `keys` that the destination's `read_action` finds for the
  # scope, read in pages its `max_page_size` allows. A read it refuses finds
  # none.
  defp existing(relationship, read_action, key, keys, scope) do
    action = Ash.Resource.Info.action(relationship.destination, read_action)

    size =
      case action do
        %{pagination: %{max_page_size: max}} when is_integer(max) and max > 0 -> max
        _no_cap -> 250
      end

    keys
    |> Enum.chunk_every(size)
    |> Enum.flat_map(fn chunk ->
      query =
        relationship.destination
        |> Ash.Query.for_read(read_action, %{}, scope: scope)
        |> Ash.Query.select(key)
        |> Ash.Query.filter(^Ash.Expr.ref(key) in ^chunk)

      query =
        case action do
          %{pagination: %{required?: true}} ->
            Ash.Query.page(query, limit: length(chunk), count: false)

          _optional ->
            Ash.Query.limit(query, length(chunk))
        end

      case Ash.read(query) do
        {:ok, %{results: records}} -> Enum.map(records, &Map.fetch!(&1, key))
        {:ok, records} when is_list(records) -> Enum.map(records, &Map.fetch!(&1, key))
        {:error, _error} -> []
      end
    end)
  end

  defp cast_or_self(attribute, value) do
    case cast(attribute, value) do
      {:ok, cast} -> cast
      _error -> value
    end
  end

  defp active?(_record, nil), do: true
  defp active?(record, %{attribute: attribute}), do: Map.get(record, attribute) == true

  # The records of `values` that `query` reads, in pages the lookup action
  # allows: Ash clamps a larger limit to its `max_page_size`, which would
  # leave the keys past it unread.
  defp read_keys(query, relationship, key, values) do
    attribute = Ash.Resource.Info.field(relationship.destination, key)

    keys =
      for value <- values,
          {:ok, cast} <- [cast(attribute, value)],
          not is_nil(cast),
          uniq: true,
          do: cast

    keys
    |> Enum.chunk_every(max_page_size(relationship))
    |> Enum.flat_map(fn chunk ->
      {records, _more?} =
        query
        |> Ash.Query.filter(^Ash.Expr.ref(key) in ^chunk)
        |> Ash.Query.page(limit: length(chunk), count: false)
        |> read(relationship)

      records
    end)
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

  defp query(relationship, key, search, scope, narrowing) do
    input =
      narrowing
      |> lookup_args()
      |> Map.merge(Utils.lookup_input(relationship.destination, search))

    relationship.destination
    |> Ash.Query.for_read(Utils.lookup_action!(relationship), input, scope: scope)
    |> Ash.Query.select(key)
    |> Utils.load_display_label()
    |> Utils.load_display_hint()
  end

  defp add_filters(query, []), do: query

  defp add_filters(query, [%Ash.Resource.Dsl.Filter{filter: filter} | rest]),
    do: query |> Ash.Query.filter(^filter) |> add_filters(rest)

  defp add_filters(query, [filter | rest]),
    do: query |> Ash.Query.filter(^filter) |> add_filters(rest)

  defp filters(%{filters: filters}) when is_list(filters), do: filters
  defp filters(_narrowing), do: []

  defp lookup_args(%{lookup_args: args}) when is_map(args), do: args
  defp lookup_args(_narrowing), do: %{}

  defp narrows?(narrowing), do: filters(narrowing) != [] or lookup_args(narrowing) != %{}

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
