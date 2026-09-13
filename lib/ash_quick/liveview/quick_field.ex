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

  defp normalize_path(path) when is_atom(path), do: path
  defp normalize_path([{_relationship, _nested}] = path), do: path

  defp label_from_path([{_relationship, nested}]) when is_atom(nested) do
    Utils.humanize(nested)
  end

  defp label_from_path([{relationship, _nested}]) do
    Utils.humanize(relationship)
  end
end
