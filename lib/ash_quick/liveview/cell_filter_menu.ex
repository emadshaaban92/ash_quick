defmodule AshQuick.LiveView.CellFilterMenu do
  @moduledoc false
  # A table cell's filter menu: the columns that draw one, its entries, read
  # off the record as the page holds it, and the row a picked entry adds to
  # the list's custom filter.
  import Phoenix.LiveView, only: [push_patch: 2, put_flash: 3]
  import Phoenix.Component, only: [assign: 3]

  alias AshQuick.LiveView.CellFilter
  alias AshQuick.LiveView.CustomFilter
  alias AshQuick.LiveView.FilterField
  alias AshQuick.LiveView.ListFilterGuard
  alias AshQuick.LiveView.QuickField
  alias AshQuick.LiveView.URLParams
  alias AshQuick.LiveView.QuickView.Options

  # A cell's filter menu, opened: its entries are read off the record as the
  # page holds it, and only the one open cell's are kept, as only the one
  # open row's actions are. A cell with none, or one the page has no menu
  # on, opens to none.
  def handle_list_events(
        "cell_filter_open",
        %{"id" => id, "column" => column},
        socket,
        _options
      ) do
    # Focus and click both open a menu (see `ListView.record_actions/1`), so
    # the second asks again for the menu already open. It is read afresh all
    # the same, as a live update may have changed the cell since the first:
    # an assign equal to the one held draws nothing.
    choices =
      case cell_choices(socket, id, column) do
        {:ok, _filter_field, choices} -> choices
        :error -> []
      end

    {:halt, assign(socket, :cell_menu, %{id: id, column: column, choices: choices})}
  end

  # A cell menu's choice: the row it adds is read off the record as the page
  # holds it, by `CellFilter.choices/4`, which drew the menu, so the event
  # names only the record, the column and which entry was picked. The entry
  # must be the one the open menu shows at that place: a live update can
  # change the cell under an open menu, and the entry read off the record now
  # would then be another than the one clicked. One naming a record not on
  # the page, a column with no menu, an entry the open menu does not show,
  # or one the cell no longer offers filters by nothing and says so.
  def handle_list_events(
        "cell_filter",
        %{"id" => id, "column" => column, "choice" => choice},
        socket,
        _options
      ) do
    with index when is_integer(index) <- choice_index(choice),
         %{id: ^id, column: ^column, choices: shown} <- socket.assigns[:cell_menu],
         {:ok, filter_field, choices} <- cell_choices(socket, id, column),
         %CellFilter.Choice{} = picked <- Enum.at(choices, index),
         ^picked <- Enum.at(shown, index) do
      row = CellFilter.row(picked, filter_field)
      filter = CustomFilter.and_also(socket.assigns.params.custom_filter, row)

      # A row past the bounds a list reads a filter in would have the list
      # refuse the whole filter; the page keeps the one it has instead.
      if CustomFilter.within_bounds?(filter) do
        params = URLParams.change_custom_filter(socket.assigns.params, filter)
        {:halt, push_patch(socket, to: URLParams.full_path(socket.assigns.path, params))}
      else
        {:halt, put_flash(socket, :error, ListFilterGuard.too_large_message())}
      end
    else
      _ -> {:halt, put_flash(socket, :error, ListFilterGuard.refused_filter_message())}
    end
  end

  def handle_list_events(event, _params, socket, _options)
      when event in ["cell_filter_open", "cell_filter"],
      do: {:halt, put_flash(socket, :error, ListFilterGuard.refused_filter_message())}

  # What the cell of record `id` in `column` offers, and the `FilterField` its
  # rows name: only a cell of a column the page draws a menu on, of a record
  # on the page.
  defp cell_choices(socket, id, column) when is_binary(id) and is_binary(column) do
    with %{filter_field: %FilterField{} = filter_field, emptiness?: emptiness?} <-
           (socket.assigns[:cell_filters] || %{})[column],
         %QuickField{path: path} <-
           Enum.find(socket.assigns.fields, &(QuickField.data_field(&1) == column)),
         %{} = record <- Enum.find(socket.assigns.data.results, &(to_string(&1.id) == id)) do
      timezone = AshQuick.Scope.timezone(socket.assigns[:scope])
      value = QuickField.resolve_value(record, path)

      {:ok, filter_field,
       CellFilter.choices(filter_field, value, timezone, emptiness?: emptiness?)}
    else
      _ -> :error
    end
  end

  defp cell_choices(_socket, _id, _column), do: :error

  @doc """
  The list's columns whose cells offer to filter the list by their value, as
  `CellFilter.columns/4` gives them, for `fields`, the columns drawn: Is
  Empty and Is Not Empty are left out on a field a field policy hides on some
  of the reader's rows, which the read refuses either on
  (`ListFilterGuard.drop_refused_rows/4`), so an entry offering one could
  only ever end in the refused-filter flash, and an empty cell offers
  nothing. Asked per navigation, as the columns and the filter's fields are.
  """
  def cell_filters(socket, fields, action, %Options{} = options) do
    filterable = socket.assigns.params.filterable

    case CellFilter.columns(fields, options.resource, filterable) do
      columns when columns == %{} ->
        columns

      columns ->
        partly_hidden =
          ListFilterGuard.hidden_fields(
            Map.keys(columns),
            ListFilterGuard.listed_fields(options.resource, options),
            action,
            socket.assigns[:scope],
            filter_is: false
          )

        CellFilter.columns(fields, options.resource, filterable, partly_hidden)
    end
  end

  # Which entry of a cell's menu was picked. `Enum.at/2` reads a negative
  # index from the end, so none is taken.
  defp choice_index(choice) when is_integer(choice) and choice >= 0, do: choice

  defp choice_index(choice) when is_binary(choice) do
    case Integer.parse(choice) do
      {index, ""} when index >= 0 -> index
      _ -> nil
    end
  end

  defp choice_index(_choice), do: nil
end
