defmodule AshQuick.LiveView.CustomFilter do
  @moduledoc false
  @derive {JSON.Encoder, except: [:uuid]}
  @enforce_keys [:uuid, :operator]
  defstruct [:uuid, :operator, :field_name, :value, :children]

  def add_filter(%__MODULE__{uuid: uuid, children: children} = filter, uuid, "true")
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
    |> add_filter(new_uuid, "false")
  end

  def add_filter(%__MODULE__{uuid: uuid, children: children} = filter, uuid, "false")
      when is_list(children) do
    %__MODULE__{
      filter
      | children:
          children ++
            [
              %__MODULE__{
                uuid: Ash.UUID.generate(),
                field_name: "id",
                operator: "equals",
                value: ""
              }
            ]
    }
  end

  def add_filter(%__MODULE__{children: children} = filter, uuid, nested) when is_list(children) do
    %__MODULE__{filter | children: Enum.map(children, &add_filter(&1, uuid, nested))}
  end

  def add_filter(%__MODULE__{} = filter, _uuid, _nested) do
    filter
  end

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
    %{field_name => %{"like" => "#{value}%"}}
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

  def to_string!(%__MODULE__{} = filter),
    do: filter |> JSON.encode!() |> :base64.encode()

  def from_string!(filter_string) do
    filter_string |> :base64.decode() |> JSON.decode!() |> from_map()
  end

  defp from_map(%{"children" => children} = filter_map)
       when is_list(children) and children != [] do
    filter_map
    |> Map.put("uuid", Ash.UUID.generate())
    |> Map.put("children", Enum.map(children, &from_map/1))
    |> Enum.into(%{}, fn {key, val} -> {String.to_existing_atom(key), val} end)
    |> then(&struct(__MODULE__, &1))
  end

  defp from_map(%{} = filter_map) do
    filter_map
    |> Map.put("uuid", Ash.UUID.generate())
    |> Enum.into(%{}, fn {key, val} -> {String.to_existing_atom(key), val} end)
    |> then(&struct(__MODULE__, &1))
  end
end
