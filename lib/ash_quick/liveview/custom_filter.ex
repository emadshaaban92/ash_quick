defmodule AshQuick.LiveView.CustomFilter do
  @moduledoc false
  @derive {JSON.Encoder, except: [:uuid]}
  @enforce_keys [:uuid, :operator]
  defstruct [:uuid, :operator, :field_name, :value, :children]

  alias AshQuick.LiveView.FilterDatetime

  # The operators that compare a field with no value.
  @valueless ~w(is_nil is_not_nil)

  @string_types [Ash.Type.String, Ash.Type.CiString]

  @doc """
  Adds a row, or a group holding one row, under the group `uuid` names.

  `leaf` is the row's starting `field_name` and `operator`: the form's first
  offered field, since no field is one every resource offers.
  """
  def add_filter(filter, uuid, nested, leaf)

  def add_filter(%__MODULE__{uuid: uuid, children: children} = filter, uuid, "true", leaf)
      when is_list(children) do
    new_uuid = Ash.UUID.generate()

    %__MODULE__{
      filter
      | children:
          children ++
            [
              %__MODULE__{
                uuid: new_uuid,
                operator: "and",
                children: []
              }
            ]
    }
    |> add_filter(new_uuid, "false", leaf)
  end

  def add_filter(%__MODULE__{uuid: uuid, children: children} = filter, uuid, "false", leaf)
      when is_list(children) do
    %__MODULE__{filter | children: children ++ [new_leaf(leaf)]}
  end

  def add_filter(%__MODULE__{children: children} = filter, uuid, nested, leaf)
      when is_list(children) do
    %__MODULE__{filter | children: Enum.map(children, &add_filter(&1, uuid, nested, leaf))}
  end

  def add_filter(%__MODULE__{} = filter, _uuid, _nested, _leaf) do
    filter
  end

  @doc "A row comparing `leaf`'s field by its operator, with no value yet."
  def new_leaf(%{field_name: field_name, operator: operator}) do
    %__MODULE__{uuid: Ash.UUID.generate(), field_name: field_name, operator: operator, value: ""}
  end

  @doc "The node `uuid` names anywhere in `filter`'s tree, or `nil`."
  def find(%__MODULE__{uuid: uuid} = filter, uuid), do: filter

  def find(%__MODULE__{children: children}, uuid) when is_list(children),
    do: Enum.find_value(children, &find(&1, uuid))

  def find(%__MODULE__{}, _uuid), do: nil

  def update_filter(%__MODULE__{uuid: uuid} = filter, uuid, key, value) do
    Map.put(filter, key, value)
  end

  def update_filter(%__MODULE__{children: children} = filter, uuid, key, value)
      when is_list(children) do
    %__MODULE__{filter | children: Enum.map(children, &update_filter(&1, uuid, key, value))}
  end

  def update_filter(%__MODULE__{} = filter, _uuid, _key, _value) do
    filter
  end

  def remove_filter(%__MODULE__{children: children} = filter, uuid) when is_list(children) do
    %__MODULE__{
      filter
      | children:
          children |> Enum.reject(&(&1.uuid == uuid)) |> Enum.map(&remove_filter(&1, uuid))
    }
  end

  def remove_filter(%__MODULE__{} = filter, _uuid) do
    filter
  end

  @doc """
  `filter` without the rows that name one of `field_names`, anywhere in its
  tree, or `nil` when `filter` is itself such a row.
  """
  def reject_fields(filter, field_names), do: reject_rows(filter, &(&1.field_name in field_names))

  @doc """
  `filter` without the rows `reject?` answers true for, anywhere in its tree,
  or `nil` when `filter` is itself such a row, or is `nil`.
  """
  def reject_rows(nil, _reject?), do: nil

  def reject_rows(%__MODULE__{children: [_ | _] = children} = filter, reject?) do
    children =
      children
      |> Enum.map(&reject_rows(&1, reject?))
      |> Enum.reject(&is_nil/1)

    %__MODULE__{filter | children: children}
  end

  def reject_rows(%__MODULE__{} = filter, reject?),
    do: if(reject?.(filter), do: nil, else: filter)

  @doc """
  `filter` without the node `uuid` names, or `nil` when what is left filters by
  nothing: the list then reads as it would with no filter, and so does its URL.
  """
  def without(%__MODULE__{uuid: uuid}, uuid), do: nil

  def without(%__MODULE__{} = filter, uuid) do
    filter = remove_filter(filter, uuid)
    if applied?(filter), do: filter
  end

  @doc """
  Whether `filter` filters by anything: a row with a field and a value, or
  with an operator that takes none, as Is Empty, or a group holding one. A row
  left without a value is skipped by `build_ash_filter/2`, and so is a group
  of only such rows.
  """
  def applied?(%__MODULE__{children: [_ | _] = children}), do: Enum.any?(children, &applied?/1)

  def applied?(%__MODULE__{field_name: field_name, operator: operator, value: value}),
    do:
      is_binary(field_name) and is_binary(operator) and
        (operator in @valueless or has_value?(value))

  defp has_value?(value) when is_list(value), do: Enum.any?(value, &has_value?/1)
  defp has_value?(value), do: value not in [nil, ""]

  @doc """
  What a row's value is, by its operator: `:none` for Is Empty and Is Not
  Empty, which compare with nothing; `:list` for Any Of; `:day` for On Day,
  a date naming a whole day of a timestamp; and `:scalar` for the rest.
  """
  def value_shape(operator) when operator in @valueless, do: :none
  def value_shape("in"), do: :list
  def value_shape("on"), do: :day
  def value_shape(_operator), do: :scalar

  @doc """
  The value a row keeps when its operator changes from `from` to `to`: as it
  was when both take the same kind of value, one value in or out of a list,
  and nothing otherwise, since a date is no instant and neither is anything
  Is Empty compares with.
  """
  def reshape_value(value, from, to) do
    case {value_shape(from), value_shape(to)} do
      {same, same} -> value
      {:scalar, :list} -> if has_value?(value), do: [value], else: []
      {:list, :scalar} -> value |> List.wrap() |> Enum.find("", &has_value?/1)
      {_, :list} -> []
      _ -> ""
    end
  end

  @doc """
  The nodes the list shows as one chip each: the root's own rows and groups
  that filter by something, or the root itself when a link made it a row.
  """
  def chips(%__MODULE__{children: children}) when is_list(children),
    do: Enum.filter(children, &applied?/1)

  def chips(%__MODULE__{} = filter), do: if(applied?(filter), do: [filter], else: [])

  @doc "The rows of `filter`'s tree that filter by something, in order."
  def applied_leaves(%__MODULE__{} = filter),
    do: filter |> leaves() |> Enum.filter(&applied?/1)

  @doc """
  The fields a row can name on `resource`, by the name a row holds them under.
  """
  def fields_by_name(resource) do
    resource
    |> Ash.Resource.Info.fields([:attributes, :aggregates, :calculations])
    |> Map.new(&{to_string(&1.name), &1})
  end

  @doc """
  `value` cast by `field`'s type, as Ash casts a filter's values: with
  `Ash.Type.coerce/3`, which differs from `cast_input/3` for some types, an
  atom among them, which `cast_input/3` accepts only when the VM already
  knows it.

  A link can pair any field with any value, and some types raise on one they
  were never meant to see, as a list type handed a string reaches
  `Enumerable`. Only such errors read as the value being invalid; anything
  else a type raises is a bug and is left to surface.
  """
  def cast_value(field, value) do
    Ash.Type.coerce(field.type, value, Map.get(field, :constraints) || [])
  rescue
    _ in [ArgumentError, FunctionClauseError, Protocol.UndefinedError] -> {:error, "is invalid"}
  end

  @doc """
  A row's value cast as its operator reads it: nothing for Is Empty, each
  value of Any Of by `field`'s type, a date for On Day, and the value by
  `field`'s type otherwise. The first value of a list that will not cast is
  the error.

  On Day's date is read as `build_ash_filter/2` reads it, by
  `FilterDatetime.day_range/3`: an ISO 8601 date, and a day in `timezone`,
  which a zone the time zone database cannot load has none of. The row says
  so, rather than the read refusing the whole filter.
  """
  def cast_row_value(field, operator, value, timezone \\ AshQuick.Config.timezone()) do
    case value_shape(operator) do
      :none ->
        {:ok, nil}

      :day ->
        case FilterDatetime.day_range(value, timezone) do
          {:ok, _from, _to} -> Date.from_iso8601(value)
          :error -> {:error, "is invalid"}
        end

      :list ->
        value |> List.wrap() |> Enum.filter(&has_value?/1) |> cast_values(field, [])

      :scalar ->
        cast_value(field, value)
    end
  end

  defp cast_values([], _field, cast), do: {:ok, Enum.reverse(cast)}

  defp cast_values([value | rest], field, cast) do
    case cast_value(field, value) do
      {:ok, value} -> cast_values(rest, field, [value | cast])
      error -> error
    end
  end

  @doc """
  The filter Ash reads `filter` as, or `nil` when it filters by nothing.

  Options:

    * `:timezone` — the zone On Day reads its date in, as the instants from
      that day's first moment up to the next day's: the zone the list shows
      timestamps in, `AshQuick.Config.timezone/0`, by default.
    * `:fields` — the resource's fields by name, as `fields_by_name/1` gives
      them. Is Empty on a string also keeps one holding `""`, which reads as
      empty in the list, and only a field's type says it is a string.
  """
  def build_ash_filter(filter, opts \\ []) do
    timezone = Keyword.get_lazy(opts, :timezone, &AshQuick.Config.timezone/0)
    build(filter, timezone, Keyword.get(opts, :fields, %{}))
  end

  defp build(%__MODULE__{operator: operator, children: children}, timezone, fields)
       when is_list(children) and children != [] do
    case Enum.map(children, &build(&1, timezone, fields)) |> Enum.reject(&is_nil/1) do
      [] -> nil
      filters -> %{operator => filters}
    end
  end

  defp build(%__MODULE__{field_name: field_name, operator: operator}, _timezone, fields)
       when is_binary(field_name) and operator in @valueless do
    is_nil = %{field_name => %{"is_nil" => operator == "is_nil"}}

    case {fields[field_name], operator} do
      {%{type: type}, "is_nil"} ->
        if string?(type),
          do: %{"or" => [is_nil, %{field_name => %{"eq" => ""}}]},
          else: is_nil

      {%{type: type}, "is_not_nil"} ->
        if string?(type),
          do: %{"and" => [is_nil, %{field_name => %{"not_eq" => ""}}]},
          else: is_nil

      _ ->
        is_nil
    end
  end

  # A link can hand Any Of one value rather than a list.
  defp build(
         %__MODULE__{field_name: field_name, operator: "in", value: value},
         _timezone,
         _fields
       )
       when is_binary(field_name) do
    case value |> List.wrap() |> Enum.filter(&has_value?/1) do
      [] -> nil
      values -> %{field_name => %{"in" => values}}
    end
  end

  # On Day filters by a day only when it can read one: a date that will not
  # parse, or a zone that will not load, filters by nothing, as a row without
  # a value does. The form refuses either under the row, with
  # `cast_row_value/4`, and the list drops a link's before the read, with the
  # refused-filter flash, so neither is applied as something else: compared
  # as written, a timestamp would cast a bare date as its midnight UTC, and a
  # datetime string as that instant.
  defp build(%__MODULE__{field_name: field_name, operator: "on", value: value}, timezone, _fields)
       when is_binary(field_name) do
    case FilterDatetime.day_range(value, timezone) do
      {:ok, from, to} -> %{field_name => %{"gte" => from, "lt" => to}}
      :error -> nil
    end
  end

  defp build(
         %__MODULE__{field_name: field_name, operator: "not_contains", value: value},
         _timezone,
         _fields
       )
       when is_binary(field_name) and is_binary(value) and value != "" do
    %{"not" => %{field_name => %{"contains" => value}}}
  end

  defp build(
         %__MODULE__{field_name: field_name, operator: operator, value: value},
         _timezone,
         _fields
       )
       when is_binary(field_name) and operator in ["starts_with", "ends_with"] and
              is_binary(value) and value != "" do
    # Ash's own predicates rather than `like`, which only AshPostgres defines
    # and which would read a `%` or `_` in the value as a wildcard.
    %{field_name => %{"string_#{operator}" => value}}
  end

  defp build(
         %__MODULE__{field_name: field_name, operator: operator, value: value},
         _timezone,
         _fields
       )
       when is_binary(field_name) and is_binary(operator) and not is_nil(value) and value != "" do
    %{field_name => %{operator => value}}
  end

  defp build(%__MODULE__{}, _timezone, _fields) do
    nil
  end

  # A string, or a type built on one, as `AshQuick.AshTypes.Text` is.
  defp string?(type) do
    type = Ash.Type.get_type(type)

    cond do
      type in @string_types -> true
      Ash.Type.NewType.new_type?(type) -> string?(Ash.Type.NewType.subtype_of(type))
      true -> false
    end
  end

  @doc """
  A row's value as written: a link's can be any JSON, and a list, as Any Of
  takes, reads as its values joined by commas rather than as iodata, which
  raises for most lists.
  """
  def as_written(value) when is_binary(value), do: value
  def as_written(value) when is_list(value), do: Enum.map_join(value, ", ", &as_written/1)
  def as_written(value) when is_number(value) or is_atom(value), do: to_string(value)
  def as_written(value), do: inspect(value)

  @doc """
  The field names `filter` names anywhere in its tree, once each, without the
  values it compares them with.
  """
  def field_names(%__MODULE__{} = filter),
    do:
      filter |> leaves() |> Enum.map(& &1.field_name) |> Enum.filter(&is_binary/1) |> Enum.uniq()

  @doc """
  The values `filter` compares its fields with, anywhere in its tree, as the
  strings they were typed as, each of a list's on its own.
  """
  def values(%__MODULE__{} = filter) do
    for %{value: value} <- leaves(filter),
        value <- List.wrap(value),
        is_binary(value) or is_number(value),
        value = to_string(value),
        value != "",
        uniq: true,
        do: value
  end

  @doc """
  Whether the form shows `node` as a group: one holding nodes, or one whose
  rows were all removed. A node naming a field with `children: []`, as a link
  can write one, is a row, as `leaves/1` and `build_ash_filter/2` read it.
  """
  def group?(%__MODULE__{children: [_ | _]}), do: true
  def group?(%__MODULE__{children: [], field_name: nil}), do: true
  def group?(%__MODULE__{}), do: false

  @doc """
  The rows of `filter`'s tree, in order. A node with children is a group, and
  one without is a row, `children: []` included, as `build_ash_filter/2` reads
  it.
  """
  def leaves(%__MODULE__{children: [_ | _] = children}),
    do: Enum.flat_map(children, &leaves/1)

  def leaves(%__MODULE__{} = leaf), do: [leaf]

  def to_string!(%__MODULE__{} = filter),
    do: filter |> JSON.encode!() |> :base64.encode()

  @doc """
  Decodes what `to_string!/1` wrote, or `nil` for anything else.

  The encoded form travels in the URL, so this is handed strings somebody
  truncated or invented, and base64 over JSON over field names is three layers
  to be wrong at. All three mean one thing to the caller: it has not been told
  what to filter by.

  Only those three are answered, so a bug in `from_map/1` still surfaces rather
  than becoming a silent unfiltered list. Which is why base64 is asked rather
  than rescued: `:base64.decode/1` has no error type to name — malformed input
  reaches at least four different exceptions — while `Base.decode64/1` answers
  `:error` for all of them, and still decodes the padding `to_string!/1` writes.
  """
  def from_string(filter_string) when is_binary(filter_string) do
    case Base.decode64(filter_string) do
      {:ok, json} -> json |> JSON.decode!() |> from_map()
      :error -> nil
    end
  rescue
    # `String.to_existing_atom/1` on a key naming no field of this struct.
    ArgumentError -> nil
    JSON.DecodeError -> nil
  end

  defp from_map(%{"children" => children} = filter_map)
       when is_list(children) and children != [] do
    filter_map
    |> Map.put("uuid", Ash.UUID.generate())
    |> Map.put("children", children |> Enum.map(&from_map/1) |> Enum.reject(&is_nil/1))
    |> Enum.into(%{}, fn {key, val} -> {String.to_existing_atom(key), val} end)
    |> then(&struct(__MODULE__, &1))
  end

  defp from_map(%{} = filter_map) do
    filter_map
    |> Map.put("uuid", Ash.UUID.generate())
    |> Enum.into(%{}, fn {key, val} -> {String.to_existing_atom(key), val} end)
    |> then(&struct(__MODULE__, &1))
  end

  # Valid JSON that is not a filter — a bare list, a number, or one of those
  # nested under `"children"`. Answered here so that a `FunctionClauseError`
  # from this module stays distinguishable from a real bug.
  defp from_map(_), do: nil
end
