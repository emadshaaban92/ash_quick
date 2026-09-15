defmodule AshQuick.LiveView.URLParams do
  @moduledoc false
  alias AshQuick.Config
  alias AshQuick.LiveView.CustomFilter

  @default_limit 20

  defstruct id: nil,
            action: nil,
            limit: @default_limit,
            page: 1,
            search: "",
            selected_filters: [],
            custom_filter: nil,
            read_args: %{},
            show_custom_filter: false

  @doc """
  Reads a QuickView's state out of the query string.

  Nothing here may raise. This runs from `handle_params/3`, before there is a
  mounted page to flash an error on, and it is reached by anyone holding a
  link — so a value that will not parse falls back to the default it had, and
  one that will parse is still held to what it may say.
  """
  def from_url_params(params) do
    limit = params |> Map.get("limit") |> parse_limit()

    %__MODULE__{
      id: Map.get(params, "id"),
      action: params |> Map.get("action") |> parse_action(),
      limit: limit,
      page: params |> Map.get("page") |> parse_page(limit),
      search: params |> Map.get("search") |> parse_search(),
      selected_filters: params |> Map.get("selected_filters") |> parse_selected_filters(),
      custom_filter: params |> Map.get("custom_filter") |> decode_custom_filter(),
      read_args: params |> get_read_args(),
      show_custom_filter: Map.has_key?(params, "show_custom_filter")
    }
  end

  # An unknown segment stays a string. Nothing here knows the resource, so it
  # cannot tell a real action from an atom that merely happens to exist —
  # both are resolved (and rejected) against the resource later.
  defp parse_action(action) when is_binary(action) do
    String.to_existing_atom(action)
  rescue
    ArgumentError -> action
  end

  # `?action[]=x` arrives as a list, which is as much a missing action as `nil`.
  defp parse_action(_), do: nil

  # Clamped, not refused: raising the page size by hand is supported (the row
  # actions menu resolves lazily so it stays cheap), but how far is the host's
  # answer rather than the visitor's.
  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {limit, ""} -> limit |> max(1) |> min(Config.max_page_size())
      _ -> default_limit()
    end
  end

  defp parse_limit(_), do: default_limit()

  # A lowered ceiling caps what one request costs, and the request nobody typed
  # a limit into is a request like any other.
  defp default_limit, do: min(@default_limit, Config.max_page_size())

  # Bounded against the limit rather than on its own, because a page is only
  # read as an offset: `ListUtils.get_offset/2` multiplies the two, and the data
  # layer refuses a product outside a 64-bit integer. Nothing real is lost — a
  # page past the end of the data lists nothing at any depth.
  @max_offset 1_000_000_000

  defp parse_page(page, limit) when is_binary(page) do
    case Integer.parse(page) do
      {page, ""} when page > 0 -> min(page, max_page(limit))
      _ -> 1
    end
  end

  defp parse_page(_, _), do: 1

  defp max_page(limit), do: div(@max_offset, limit) + 1

  defp parse_search(search) when is_binary(search), do: search
  defp parse_search(_), do: ""

  defp parse_selected_filters(selected_filters) when is_binary(selected_filters),
    do: String.split(selected_filters, ",", trim: true)

  defp parse_selected_filters(_), do: []

  defp get_read_args(params_map) do
    params_map
    |> Enum.flat_map(fn
      {"arg__" <> key, value} -> read_arg(key, value)
      _ -> []
    end)
    |> Map.new()
  end

  # Dropped rather than carried through as a string, which is where a read
  # argument parts company with an action: an action names a route segment the
  # resource resolves and refuses by name, while an argument is passed *by*
  # name — and a name no atom was ever made for is not one the resource
  # declared, so there is nothing for it to be passed to.
  defp read_arg(key, value) do
    [{String.to_existing_atom(key), value}]
  rescue
    ArgumentError -> []
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

  # Against the effective default rather than the literal one: under a lowered
  # ceiling the limit a bare path reads is the clamped one, so that is the
  # limit a path may leave unsaid.
  defp maybe_put_limit(params_for_path, %{limit: limit}) do
    if limit == default_limit() do
      params_for_path
    else
      Map.put(params_for_path, "limit", limit)
    end
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

  # A filter is base64 over JSON over field names, so there are three separate
  # ways for a truncated copy-paste — or somebody's guess at the encoding — to
  # be undecodable. All three mean the same thing to the page: it has not been
  # told what to filter by, which is the unfiltered list rather than no list.
  defp decode_custom_filter(custom_filter) when is_binary(custom_filter) do
    CustomFilter.from_string(custom_filter)
  end

  defp decode_custom_filter(_), do: nil

  defp maybe_put_read_args(params_for_path, %{read_args: read_args}) when read_args == %{},
    do: params_for_path

  defp maybe_put_read_args(params_for_path, %{read_args: %{} = read_args}) do
    read_args
    |> Enum.into(%{}, fn {key, value} -> {"arg__#{to_string(key)}", value} end)
    |> Map.merge(params_for_path)
  end
end
