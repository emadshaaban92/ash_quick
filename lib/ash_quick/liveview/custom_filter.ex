defmodule AshQuick.LiveView.CustomFilter do
  @moduledoc false
  @derive {JSON.Encoder, except: [:uuid]}
  @enforce_keys [:uuid, :operator]
  defstruct [:uuid, :operator, :field_name, :value, :children]

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
  def reject_fields(%__MODULE__{children: [_ | _] = children} = filter, field_names) do
    children =
      children
      |> Enum.map(&reject_fields(&1, field_names))
      |> Enum.reject(&is_nil/1)

    %__MODULE__{filter | children: children}
  end

  def reject_fields(%__MODULE__{field_name: field_name} = filter, field_names),
    do: if(field_name in field_names, do: nil, else: filter)

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
  Whether `filter` filters by anything: a row with a field and a value, or a
  group holding one. A row left without a value is skipped by
  `build_ash_filter/1`, and so is a group of only such rows.
  """
  def applied?(%__MODULE__{children: [_ | _] = children}), do: Enum.any?(children, &applied?/1)

  def applied?(%__MODULE__{field_name: field_name, operator: operator, value: value}),
    do: is_binary(field_name) and is_binary(operator) and value not in [nil, ""]

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

  def build_ash_filter(%__MODULE__{operator: operator, children: children})
      when is_list(children) and children != [] do
    case Enum.map(children, &build_ash_filter/1) |> Enum.reject(&is_nil/1) do
      [] -> nil
      filters -> %{operator => filters}
    end
  end

  def build_ash_filter(%__MODULE__{
        field_name: field_name,
        operator: "starts_with",
        value: value
      })
      when is_binary(field_name) and is_binary(value) and value != "" do
    # Ash's own predicate rather than `like`, which only AshPostgres defines and
    # which would read a `%` or `_` in the value as a wildcard.
    %{field_name => %{"string_starts_with" => value}}
  end

  def build_ash_filter(%__MODULE__{
        field_name: field_name,
        operator: operator,
        value: value
      })
      when is_binary(field_name) and is_binary(operator) and not is_nil(value) and value != "" do
    %{field_name => %{operator => value}}
  end

  def build_ash_filter(%__MODULE__{}) do
    nil
  end

  @doc """
  The field names `filter` names anywhere in its tree, once each, without the
  values it compares them with.
  """
  def field_names(%__MODULE__{} = filter),
    do:
      filter |> leaves() |> Enum.map(& &1.field_name) |> Enum.filter(&is_binary/1) |> Enum.uniq()

  @doc """
  The values `filter` compares its fields with, anywhere in its tree, as the
  strings they were typed as.
  """
  def values(%__MODULE__{} = filter) do
    for %{value: value} <- leaves(filter),
        is_binary(value) or is_number(value),
        value = to_string(value),
        value != "",
        uniq: true,
        do: value
  end

  @doc """
  The rows of `filter`'s tree, in order. A node with children is a group, and
  one without is a row, `children: []` included, as `build_ash_filter/1` reads
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
