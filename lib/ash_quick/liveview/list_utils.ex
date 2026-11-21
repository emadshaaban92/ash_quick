defmodule AshQuick.LiveView.ListUtils do
  @moduledoc false
  # The list page's lifecycle: its params, its events and messages, row
  # selection and the row actions menu. The read, live rows, the filter
  # guard, export, bulk actions and the cell filter menu are in `ListRead`,
  # `ListRows`, `ListFilterGuard`, `ListExport`, `ListBulk` and
  # `CellFilterMenu`.
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 2, assign: 3, assign_new: 3]

  alias Ash.Resource.Actions
  alias AshQuick.Labels
  alias AshQuick.LiveView.URLParams
  alias AshQuick.LiveView.CellFilterMenu
  alias AshQuick.LiveView.Components.FilterForm
  alias AshQuick.LiveView.CustomFilter
  alias AshQuick.LiveView.FilterRecords
  alias AshQuick.LiveView.ListBulk
  alias AshQuick.LiveView.ListExport
  alias AshQuick.LiveView.ListFilterGuard
  alias AshQuick.LiveView.ListRead
  alias AshQuick.LiveView.ListRows
  alias AshQuick.LiveView.Liveness
  alias AshQuick.LiveView.Utils
  alias AshQuick.LiveView.QuickView.Options

  def do_handle_params(
        socket,
        %URLParams{} = params,
        %Actions.Read{get?: false} = action,
        %Options{} = options
      ) do
    {socket, params} = ListFilterGuard.drop_refused_rows(socket, params, action, options)

    params =
      URLParams.allow_filter_form(params, ListFilterGuard.offered_fields(socket, action, options))

    {socket, params, page} =
      socket |> forget_held_filter(params) |> ListRead.initial_read(params, options)

    socket
    |> assign(:params, params)
    # The records the filter's chips name, read with the list rather than as
    # the chips render.
    |> assign(
      :filter_records,
      FilterRecords.held_by_field(options.resource, params, socket.assigns[:scope])
    )
    |> assign(ListRows.fresh_screen(page))
    |> assign(:selected_rows, %{})
    |> assign(:export_data, ListExport.running_export(socket))
    # Kept across patches: an export a patch interrupted still finishes, and
    # its modal comes back, so a failed one still needs its format to retry.
    |> assign_new(:export_format, fn -> nil end)
    |> assign(:row_actions, nil)
    |> assign(:cell_menu, nil)
    |> detach_hook(:quick_view_events_hook, :handle_event)
    |> attach_hook(:quick_view_events_hook, :handle_event, fn
      event, params, socket -> handle_list_events(event, params, socket |> clear_flash(), options)
    end)
    |> detach_hook(:quick_view_info_hook, :handle_info)
    |> attach_hook(:quick_view_info_hook, :handle_info, fn
      message, socket -> handle_list_info(message, socket, options)
    end)
    |> detach_hook(:quick_view_async_hooks, :handle_async)
    |> attach_hook(:quick_view_async_hooks, :handle_async, fn
      _name, _result, socket -> {:cont, socket}
    end)
    |> set_title(options)
    |> AshPhoenix.LiveView.keep_live(
      :data,
      &ListRows.refetch_rows(&1, params, options),
      [
        initial: page,
        results: :lose,
        after_fetch: &ListRows.after_refetch(&1, &2, params, options)
      ] ++
        Liveness.list_options(
          options,
          AshQuick.Scope.tenant(socket.assigns.scope),
          socket.assigns.ash_action
        )
    )
  end

  # A filter the list was too slow to read with is held for the form, which
  # opens holding it, through the patch that takes it out of the URL, and
  # for as long as the form stays open with no other filter. See
  # `ListRead.initial_read/3`.
  defp forget_held_filter(socket, %URLParams{show_custom_filter: true, custom_filter: nil}),
    do: assign_new(socket, :held_filter, fn -> nil end)

  defp forget_held_filter(socket, _params), do: assign(socket, :held_filter, nil)

  defp set_title(socket, %{resource: resource}) do
    title =
      case Ash.Resource.Info.plural_name(resource) do
        nil -> "#{Ash.Resource.Info.short_name(resource)}s" |> Labels.name()
        name -> name |> Labels.name()
      end

    socket |> assign(page_title: title)
  end

  # Every event the list handles. A name outside it is the host's, and goes on
  # to the QuickView module; the clause below makes this the only way in, so a
  # handler added without its name here is never reached. `FormUtils` reads it
  # to keep these events off a list drawn under the action modal.
  @events ~w(search page_size new_click export close-export-modal bulk_action bulk_validate
             bulk_save bulk_close row_actions_open row_action_click toggle-filter
             table-form-change reload_list cell_filter_open cell_filter remove_filter_chip
             open_custom_filter)

  @doc false
  def events, do: @events

  # The export, bulk action and cell filter menu events are handled with the
  # rest of each, in `ListExport`, `ListBulk` and `CellFilterMenu`.
  @export_events ~w(export close-export-modal)
  @bulk_events ~w(bulk_action bulk_validate bulk_save bulk_close)
  @cell_filter_events ~w(cell_filter_open cell_filter)

  defp handle_list_events(event, _params, socket, _options) when event not in @events,
    do: {:cont, socket}

  defp handle_list_events(event, params, socket, options) when event in @export_events,
    do: ListExport.handle_list_events(event, params, socket, options)

  defp handle_list_events(event, params, socket, options) when event in @bulk_events,
    do: ListBulk.handle_list_events(event, params, socket, options)

  defp handle_list_events(event, params, socket, options) when event in @cell_filter_events,
    do: CellFilterMenu.handle_list_events(event, params, socket, options)

  defp handle_list_events("search", %{"search" => search}, socket, _options) do
    params =
      socket.assigns.params
      |> URLParams.change_search(search)

    {:halt, push_patch(socket, to: URLParams.full_path(socket.assigns.path, params))}
  end

  defp handle_list_events("page_size", %{"limit" => limit}, socket, _options) do
    params = URLParams.change_limit(socket.assigns.params, limit)

    {:halt, push_patch(socket, to: URLParams.full_path(socket.assigns.path, params))}
  end

  # The bar's Reload: the list read afresh from its URL, placeholders and all
  # dropped, the records it announced in their places.
  defp handle_list_events("reload_list", _, socket, _) do
    {:halt,
     push_patch(socket, to: URLParams.full_path(socket.assigns.path, socket.assigns.params))}
  end

  # A chip's ✕: the node it names dropped from the filter the page holds.
  # A node the filter no longer has, as a stale page can name, drops
  # nothing.
  defp handle_list_events("remove_filter_chip", %{"node" => uuid}, socket, _)
       when is_binary(uuid) do
    params = socket.assigns.params

    case params.custom_filter do
      %CustomFilter{} = filter ->
        params = URLParams.change_custom_filter(params, CustomFilter.without(filter, uuid))
        {:halt, push_patch(socket, to: URLParams.full_path(socket.assigns.path, params))}

      nil ->
        {:halt, socket}
    end
  end

  defp handle_list_events("remove_filter_chip", _, socket, _), do: {:halt, socket}

  # A group's chip opens the filter form, which shows the group's rows.
  defp handle_list_events("open_custom_filter", _, socket, _) do
    %URLParams{} = params = socket.assigns.params
    params = %URLParams{params | show_custom_filter: true}
    {:halt, push_patch(socket, to: URLParams.full_path(socket.assigns.path, params))}
  end

  defp handle_list_events("new_click", _, socket, _) do
    params =
      socket.assigns.params
      |> URLParams.to_action_params(:create)

    {:halt, push_patch(socket, to: URLParams.full_path(socket.assigns.path, params))}
  end

  # Resolved on open rather than on render — see `ListView.record_actions/1`. Only
  # the one open row is kept.
  defp handle_list_events("row_actions_open", %{"id" => id}, socket, options) do
    {:halt, assign_row_actions(socket, id, options)}
  end

  defp handle_list_events(
         "row_action_click",
         %{"id" => id, "action_name" => action_name},
         socket,
         options
       ) do
    case options.resource |> Utils.record_actions() |> Utils.offered_action(action_name) do
      nil -> {:halt, refuse_action(socket)}
      action -> {:halt, row_action(id, action, socket, options)}
    end
  end

  defp handle_list_events("toggle-filter", %{"name" => filter_name}, socket, _) do
    params =
      socket.assigns.params
      |> URLParams.toggle_filter(filter_name)

    {:halt, push_patch(socket, to: URLParams.full_path(socket.assigns.path, params))}
  end

  defp handle_list_events("table-form-change", %{"_target" => ["all"], "all" => "on"}, socket, _) do
    {:halt,
     socket
     |> assign(
       :selected_rows,
       socket.assigns.data.results |> Enum.into(%{"all" => "on"}, &{&1.id, "on"})
     )}
  end

  defp handle_list_events(
         "table-form-change",
         %{"_target" => ["all"]},
         %{assigns: %{selected_rows: %{"all" => "on"}}} = socket,
         _
       ) do
    {:halt, socket |> assign(:selected_rows, %{})}
  end

  defp handle_list_events("table-form-change", %{} = changes, socket, _) do
    {:halt, socket |> assign(:selected_rows, changes |> Map.drop(["_target", "all"]))}
  end

  defp handle_list_events(_, _, socket, _options), do: {:cont, socket}

  def selected_ids(socket) do
    for {id, "on"} <- socket.assigns.selected_rows, id != "all", do: id
  end

  # Only rows the list is showing, read through the actor's scope: a selected id
  # that is not among them is one the actor cannot read, or one that has left
  # the list since it was ticked.
  def selected_records(socket) do
    selected = selected_ids(socket)
    Enum.filter(socket.assigns.data.results, &(&1.id in selected))
  end

  # Every action opens at its own URL, over this list, and runs from there: a
  # form for one that takes input, a confirmation for one that does not. What
  # may open and run it is the modal's to decide, as it is for a typed URL.
  #
  # The list is read through the actor's scope, so an id that is not in it is
  # one the actor may not read (or that does not exist) — no row was drawn for
  # it. A hand-pushed event still names it: refuse rather than open it.
  defp row_action(id, action, socket, _options) do
    if Enum.any?(socket.assigns.data.results, &(&1.id == id)) do
      params = socket.assigns.params |> URLParams.to_action_params(action.name, id: id)
      push_patch(socket, to: URLParams.full_path(socket.assigns.path, params))
    else
      refuse_action(socket)
    end
  end

  defp handle_list_info(
         %{topic: topic, payload: %AshQuick.PubSub.Notice{} = notice},
         socket,
         options
       ) do
    # Only a topic this list still holds: one let go of may still be in the
    # mailbox, and noting it would leave a refetch owed that never runs.
    subscribed? =
      case get_in(socket.assigns, [:ash_live_config, :data, :subscribed_topics]) do
        nil -> true
        topics -> topic in topics
      end

    case subscribed? and ListRows.note_notice(socket, topic, notice, options) do
      {:ok, socket} -> {:halt, AshPhoenix.LiveView.handle_live(socket, topic, :data)}
      _ignored -> {:halt, socket}
    end
  end

  # A refetch `keep_live` deferred inside `:refetch_window` can arrive after a
  # patch to an action form, which runs no `keep_live` of its own and leaves
  # this hook in place. The list's callback reads through `ash_action`, which a
  # form has made a create, update or destroy, so it is dropped there: closing
  # the modal reads the list afresh, and refetching under it would also listen
  # again on the rows `Liveness.unsubscribe_all/2` let go of.
  defp handle_list_info({:refetch, :data, _refetch_info}, socket, _)
       when not is_struct(socket.assigns.ash_action, Actions.Read),
       do: {:halt, socket}

  defp handle_list_info({:refetch, :data, refetch_info}, socket, _) do
    {:halt, AshPhoenix.LiveView.handle_live(socket, :refetch, :data, refetch_info)}
  end

  # Apply with no row holding a value: the list without a filter, the form
  # closed, as Apply closes it.
  defp handle_list_info({FilterForm, :none}, socket, _) do
    %URLParams{} = params = URLParams.change_custom_filter(socket.assigns.params, nil)
    params = %URLParams{params | show_custom_filter: false}

    {:halt, push_patch(socket, to: URLParams.full_path(socket.assigns.path, params))}
  end

  defp handle_list_info({FilterForm, custom_filter}, socket, _) do
    params =
      socket.assigns.params
      |> URLParams.change_custom_filter(custom_filter)

    {:halt, push_patch(socket, to: URLParams.full_path(socket.assigns.path, params))}
  end

  defp handle_list_info(_, socket, _options), do: {:cont, socket}

  def refuse_action(socket) do
    socket |> put_flash(:error, AshQuick.LiveView.ActionErrors.forbidden_message())
  end

  defp assign_row_actions(socket, id, %Options{resource: resource}) do
    actions =
      case Enum.find(socket.assigns.data.results, &(&1.id == id)) do
        nil -> []
        record -> record_actions(record, resource, socket.assigns.scope)
      end

    assign(socket, :row_actions, %{id: id, actions: actions})
  end

  # An action taken from the menu changes what the menu should offer next —
  # deactivating a row replaces its Deactivate with Activate — and the row is
  # still open in front of whoever took it. One row's worth of `Ash.can?` is
  # what the whole list used to cost per render, so re-resolving the open one
  # keeps it honest for free.
  def refresh_row_actions(socket, options) do
    case socket.assigns.row_actions do
      %{id: id} -> assign_row_actions(socket, id, options)
      nil -> socket
    end
  end

  defp record_actions(record, resource, scope) do
    resource
    |> Utils.record_actions()
    |> Utils.reject_redundant_activation(record)
    |> Enum.filter(&AshQuick.can?({record, &1}, scope, :ash_quick_list))
  end
end
