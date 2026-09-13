defmodule AshQuick.LiveView.URLParams do
  @moduledoc false
  alias AshQuick.LiveView.CustomFilter

  defstruct id: nil,
            action: nil,
            limit: 20,
            page: 1,
            search: "",
            selected_filters: [],
            custom_filter: nil,
            read_args: %{},
            show_custom_filter: false

  def from_url_params(params) do
    %__MODULE__{
      id: Map.get(params, "id"),
      action: Map.get(params, "action") |> parse_action(),
      limit: Map.get(params, "limit", "20") |> String.to_integer(),
      page: Map.get(params, "page", "1") |> String.to_integer(),
      search: Map.get(params, "search", ""),
      selected_filters: Map.get(params, "selected_filters", "") |> String.split(",", trim: true),
      custom_filter: Map.get(params, "custom_filter") |> decode_custom_filter(),
      read_args: params |> get_read_args(),
      show_custom_filter: Map.has_key?(params, "show_custom_filter")
    }
  end

  defp parse_action(nil), do: nil

  # An unknown segment stays a string. Nothing here knows the resource, so it
  # cannot tell a real action from an atom that merely happens to exist —
  # both are resolved (and rejected) against the resource later.
  defp parse_action(action) when is_binary(action) do
    String.to_existing_atom(action)
  rescue
    ArgumentError -> action
  end

  defp get_read_args(params_map) do
    params_map
    |> Map.filter(fn {key, _} -> String.starts_with?(key, "arg__") end)
    |> Enum.into(%{}, fn {"arg__" <> key, value} -> {String.to_existing_atom(key), value} end)
  end

  def path_for_page(base_path, params, page), do: full_path(base_path, %{params | page: page})

  def full_path(base_path, params) do
    "#{path_no_params(base_path, params)}?#{params |> params_for_path() |> URI.encode_query()}"
    |> String.trim_trailing("?")
  end

  defp path_no_params(base_path, %__MODULE__{id: nil, action: nil}), do: base_path

  defp path_no_params(base_path, %__MODULE__{id: nil, action: action}) when action != nil,
    do: "#{base_path}/#{action}"

  defp path_no_params(base_path, %__MODULE__{id: id, action: nil}) when id != nil,
    do: "#{base_path}/#{id}"

  defp path_no_params(base_path, %__MODULE__{id: id, action: action})
       when id != nil and action != nil,
       do: "#{base_path}/#{id}/#{action}"

  def to_list_params(%__MODULE__{} = params, opts \\ []) do
    %__MODULE__{params | id: nil, action: Keyword.get(opts, :action)}
  end

  def to_details_params(%__MODULE__{} = params, id, opts \\ []) do
    %__MODULE__{params | id: id, action: Keyword.get(opts, :action)}
  end

  def to_action_params(%__MODULE__{} = params, action, opts \\ []) do
    %__MODULE__{params | action: action, id: Keyword.get(opts, :id)}
  end

  def change_search(%__MODULE__{} = params, nil), do: %{params | page: 1, search: ""}

  def change_search(%__MODULE__{} = params, search),
    do: %{params | page: 1, search: String.trim(search)}

  def toggle_filter(%__MODULE__{selected_filters: selected_filters} = params, filter) do
    if filter in selected_filters do
      %__MODULE__{params | page: 1, selected_filters: List.delete(selected_filters, filter)}
    else
      %__MODULE__{params | page: 1, selected_filters: [filter | selected_filters]}
    end
  end

  def change_custom_filter(%__MODULE__{} = params, %CustomFilter{} = custom_filter),
    do: %__MODULE__{params | page: 1, custom_filter: custom_filter, show_custom_filter: false}

  def change_custom_filter(%__MODULE__{} = params, nil),
    do: %__MODULE__{params | page: 1, custom_filter: nil}

  def toggle_show_custom_filter(%__MODULE__{} = params),
    do: %__MODULE__{params | show_custom_filter: not params.show_custom_filter}

  defp params_for_path(params) do
    %{}
    |> maybe_put_limit(params)
    |> maybe_put_page(params)
    |> maybe_put_search(params)
    |> maybe_put_selected_filters(params)
    |> maybe_put_custom_filter(params)
    |> maybe_put_read_args(params)
    |> maybe_put_show_custom_filter(params)
  end

  defp maybe_put_limit(params_for_path, %{limit: 20}), do: params_for_path

  defp maybe_put_limit(params_for_path, %{limit: limit}) do
    Map.put(params_for_path, "limit", limit)
  end

  defp maybe_put_page(params_for_path, %{page: 1}), do: params_for_path

  defp maybe_put_page(params_for_path, %{page: page}) do
    Map.put(params_for_path, "page", page)
  end

  defp maybe_put_search(params_for_path, %{search: ""}), do: params_for_path

  defp maybe_put_search(params_for_path, %{search: search}) do
    Map.put(params_for_path, "search", search)
  end

  defp maybe_put_selected_filters(params_for_path, %{selected_filters: []}), do: params_for_path

  defp maybe_put_selected_filters(params_for_path, %{selected_filters: selected_filters}) do
    Map.put(
      params_for_path,
      "selected_filters",
      selected_filters |> Enum.join(",") |> String.trim(",")
    )
  end

  defp maybe_put_custom_filter(params_for_path, %{custom_filter: nil}), do: params_for_path

  defp maybe_put_custom_filter(params_for_path, %{custom_filter: %CustomFilter{} = custom_filter}) do
    Map.put(
      params_for_path,
      "custom_filter",
      custom_filter |> CustomFilter.to_string!()
    )
  end

  defp maybe_put_show_custom_filter(params_for_path, %{show_custom_filter: false}),
    do: params_for_path

  defp maybe_put_show_custom_filter(params_for_path, %{}) do
    Map.put(
      params_for_path,
      "show_custom_filter",
      true
    )
  end

  defp decode_custom_filter(nil), do: nil

  defp decode_custom_filter(custom_filter) when is_binary(custom_filter) do
    custom_filter |> CustomFilter.from_string!()
  end

  defp maybe_put_read_args(params_for_path, %{read_args: read_args}) when read_args == %{},
    do: params_for_path

  defp maybe_put_read_args(params_for_path, %{read_args: %{} = read_args}) do
    read_args
    |> Enum.into(%{}, fn {key, value} -> {"arg__#{to_string(key)}", value} end)
    |> Map.merge(params_for_path)
  end
end
