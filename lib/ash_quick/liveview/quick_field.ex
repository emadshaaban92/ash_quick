defmodule AshQuick.LiveView.QuickField do
  @moduledoc false
  alias AshQuick.LiveView.Utils

  defstruct [:path, :label, :widget]

  def normalize(field) when is_atom(field) do
    %__MODULE__{path: field, label: Utils.humanize(field)}
  end

  def normalize([{_relationship, _nested}] = path) do
    %__MODULE__{path: path, label: label_from_path(path)}
  end

  def normalize({path, label}) when is_binary(label) do
    %__MODULE__{path: normalize_path(path), label: label}
  end

  def normalize({path, opts}) when is_atom(path) and is_list(opts) do
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

  def normalize({[{_, _}] = path, opts}) when is_list(opts) do
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

  @doc """
  The value a widget is handed for `path` on `record`.

  A relationship path walks through a related record that may not be there: an
  empty nullable `belongs_to` reads as `nil`, and so does everything past it.
  The `nil` clause comes first because `nil` is itself an atom, so the
  `is_atom/1` clause would otherwise take it and `Map.get/2` on `nil` raises.
  """
  def resolve_value(nil, _path), do: nil
  def resolve_value(record, path) when is_atom(path), do: Map.get(record, path)

  def resolve_value(record, [{relationship, nested}]) do
    record |> Map.get(relationship) |> resolve_value(nested)
  end

  defp normalize_path(path) when is_atom(path), do: path
  defp normalize_path([{_relationship, _nested}] = path), do: path

  defp label_from_path([{_relationship, nested}]) when is_atom(nested) do
    Utils.humanize(nested)
  end

  defp label_from_path([{relationship, _nested}]) do
    Utils.humanize(relationship)
  end
end
