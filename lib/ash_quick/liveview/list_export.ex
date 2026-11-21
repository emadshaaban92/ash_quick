defmodule AshQuick.LiveView.ListExport do
  @moduledoc false
  # The list's export: its events, the query it streams, which is the page's
  # own, and the run, in a task.
  require Ash.Query
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 2, assign: 3]
  use Gettext, backend: AshQuick.Gettext

  alias Phoenix.LiveView.AsyncResult
  alias AshQuick.LiveView.ListRead
  alias AshQuick.LiveView.ListUtils
  alias AshQuick.LiveView.Utils

  # A patch closes a finished export's modal and leaves a running one in
  # place. The running one is also what refuses a second export, so dropping
  # it here would let a patch between two requests run them side by side.
  def running_export(%{assigns: %{export_data: %AsyncResult{loading: loading} = export}})
      when not is_nil(loading),
      do: export

  def running_export(_socket), do: nil

  # One export per page at a time. Each one streams a whole list, so a second
  # asked for while the first runs is left unanswered rather than run beside it.
  def handle_list_events(
        "export",
        _params,
        %{assigns: %{export_data: %AsyncResult{loading: loading}}} = socket,
        _options
      )
      when not is_nil(loading),
      do: {:halt, socket}

  # A format the modal does not offer is a forged event, left unanswered
  # before anything runs: a span would carry whatever string it named.
  def handle_list_events("export", %{"format" => format}, socket, _options)
      when format not in ["csv", "xlsx"],
      do: {:halt, socket}

  def handle_list_events("export", %{"format" => format}, socket, options) do
    selection = export_selection(socket)

    # A column every row would export blank is left out, as it is on the page.
    options = %{
      options
      | export_fields:
          Utils.visible_fields(
            options.export_fields,
            options.resource,
            socket.assigns.ash_action,
            socket.assigns.scope
          )
    }

    export_query =
      socket
      |> build_export_query(selection, options)
      |> Utils.load_fields(options.export_fields, strict?: true)

    # The header and the dates are in the reader's language, and a task
    # inherits no locale. The scope's is the one a host puts on its pages;
    # set process-wide, the host's backend falls back to it.
    locale = AshQuick.Scope.locale(socket.assigns.scope)
    timezone = AshQuick.Scope.timezone(socket.assigns.scope)

    # Read here: the task has no socket.
    metadata = %{
      quick_view: socket.view,
      resource: options.resource,
      format: String.to_existing_atom(format),
      selection: if(selection == :all, do: :all, else: :selected),
      scope: socket.assigns.scope
    }

    socket =
      case Ash.Scope.ToOpts.get_actor(socket.assigns.scope) do
        {:ok, actor} when not is_nil(actor) ->
          # The format stays with the modal, so its Retry runs this same export.
          socket
          |> assign(:export_format, format)
          |> assign_async(:export_data, fn ->
            Gettext.put_locale(locale)

            run_export(export_query, actor, options, metadata, timezone)
          end)

        _ ->
          socket |> put_flash(:error, gettext("Unable to determine current user for export"))
      end

    {:halt, socket}
  end

  def handle_list_events("close-export-modal", _, socket, _) do
    socket =
      socket
      |> cancel_async(socket.assigns.export_data)
      |> assign(export_data: nil, export_format: nil)

    {:halt, socket}
  end

  def handle_list_events(_, _, socket, _options), do: {:cont, socket}

  # The page's own query either way: a selection narrows what the page lists,
  # it does not step outside the base filter, the filters or the search.
  defp build_export_query(socket, selection, options) do
    socket
    |> ListRead.read_query(socket.assigns.params, options)
    |> only_selected(selection)
  end

  defp only_selected(query, :all), do: query
  defp only_selected(query, ids) when is_list(ids), do: Ash.Query.filter(query, id in ^ids)

  # Nothing ticked exports the whole list. Anything ticked exports the ticked
  # rows the page is showing, as a bulk action runs over them: an id that is
  # not among them came from somewhere other than this page's checkboxes.
  defp export_selection(socket) do
    case ListUtils.selected_ids(socket) do
      [] -> :all
      _ticked -> Enum.map(ListUtils.selected_records(socket), & &1.id)
    end
  end

  # Timed as `[:ash_quick, :export]` (see `AshQuick.Telemetry`).
  defp run_export(query, actor, options, metadata, timezone) do
    AshQuick.Telemetry.span([:export], metadata, fn ->
      case AshQuick.LiveView.ExportUtils.generate_export_url(
             query,
             actor,
             options,
             metadata.format,
             timezone
           ) do
        {:ok, url} ->
          {{:ok, %{export_data: %{url: url}}}, %{result: :ok}}

        # A refusal, not a failure: the modal words it and offers no Retry,
        # since the same list would be refused again.
        {:error, {:too_many_rows, _max}} = refused ->
          {refused, %{result: :too_many_rows}}
      end
    end)
  end
end
