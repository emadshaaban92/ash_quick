defmodule AshQuick.LiveView.QuickView.Page do
  @moduledoc false
  # The page's own lifecycle: what a mount assigns, the load each action
  # shape goes through, the assigns the generic templates render from, and
  # leaving a page for a URL it cannot serve.
  import Phoenix.Component, only: [assign: 2, assign: 3]
  alias Ash.Resource.Actions
  alias Phoenix.LiveView.JS
  alias AshQuick.LiveView.URLParams
  alias AshQuick.LiveView.QuickView.Options
  alias AshQuick.LiveView.ListUtils
  alias AshQuick.LiveView.CellFilterMenu
  alias AshQuick.LiveView.DetailsUtils
  alias AshQuick.LiveView.FormUtils

  def do_mount(socket, _params, _session, %Options{} = options) do
    socket
    # The layout renders the nav, so the option has to reach it from here — a
    # view is what knows it wants the width, and the layout is what wraps it.
    |> assign(:sidebar, options.sidebar)
    |> assign(:filters, options.filters)
    # Once: a record-less `Ash.can?` answers from the scope alone.
    |> assign(:bulk_actions, AshQuick.LiveView.BulkActions.menu(options, socket))
    |> assign(:ash_quick_bulk, nil)
    |> assign(:action_running, false)
  end

  def do_handle_params(socket, params, ash_action, %Options{} = options) do
    socket
    |> assign(:ash_quick_bulk, nil)
    |> load_page(params, ash_action, options)
    |> prepare_assigns(ash_action, options)
  end

  # Timed as `[:ash_quick, :page, :load]` (see `AshQuick.Telemetry`).
  defp load_page(socket, params, ash_action, %Options{} = options) do
    AshQuick.Telemetry.span(
      [:page, :load],
      %{
        quick_view: socket.view,
        resource: options.resource,
        action: ash_action.name,
        page: page(params, ash_action),
        scope: socket.assigns[:scope]
      },
      fn -> {load_params(socket, params, ash_action, options), %{}} end
    )
  end

  defp page(%{id: nil}, %Actions.Read{get?: false}), do: :list
  defp page(_params, %Actions.Read{}), do: :details
  defp page(_params, %{type: type}), do: type

  defp load_params(
         socket,
         %{id: nil} = params,
         %Actions.Read{get?: false} = action,
         %Options{} = options
       ) do
    ListUtils.do_handle_params(socket, params, action, options)
  end

  defp load_params(socket, %{id: _} = params, %Actions.Read{} = action, %Options{} = options) do
    DetailsUtils.do_handle_params(socket, params, action, options)
  end

  defp load_params(
         socket,
         %{id: nil} = params,
         %Actions.Create{} = action,
         %Options{} = options
       ) do
    FormUtils.do_handle_params(socket, params, action, options)
  end

  defp load_params(socket, %{id: _} = params, %type{} = action, %Options{} = options)
       when type in [Actions.Update, Actions.Destroy] do
    FormUtils.do_handle_params(socket, params, action, options)
  end

  # Assigns what the generic templates render from, beyond what
  # `load_params/4` loaded: the component id, the field list, the bulk action
  # menu, the pagination path builder, and the list's linker. After the load because the
  # list read can still drop a refused filter from `:params`, and
  # `path_for_page` has to build from what the page rendered; before
  # `after_handle_params/2` so a host can still override any of these.
  #
  # It runs against the socket rather than inside `render/1`. A key assigned
  # during a render is never stored on the socket, so the next render finds it
  # absent again and change tracking marks it changed every time, re-rendering
  # every part of the template that reads it — every row, through `@fields` —
  # on every event. Assigned here, a key is only marked changed when its value
  # actually differs, which is when the URL moved.
  #
  # Public only so a test can drive it without a data layer to read through.
  def prepare_assigns(socket, ash_action, %Options{} = options) do
    do_prepare_assigns(socket, socket.assigns.params, ash_action, options)
  end

  defp do_prepare_assigns(
         socket,
         %{id: nil},
         %Actions.Read{get?: false} = action,
         %Options{} = options
       ) do
    %{path: path, params: params} = socket.assigns

    fields = visible_fields(socket, options.list_fields, action, options)

    socket
    |> assign(:id, "#{Ash.Resource.Info.trace_name(options.resource)}-list")
    |> assign(:fields, fields)
    # The columns whose cells offer to filter the list by their value.
    |> assign(:cell_filters, CellFilterMenu.cell_filters(socket, fields, action, options))
    |> assign(:sortable, options.list_sortable)
    |> assign(:filterable, options.list_filterable)
    |> assign(:new_action_label, options.new_action_label)
    |> assign(:new_click, fn -> JS.push("new_click") end)
    |> assign(:actions, socket.assigns[:bulk_actions] || [])
    |> assign(:path_for_page, &URLParams.path_for_page(path, params, &1))
    |> assign(:linker, list_linker(socket, options))
  end

  defp do_prepare_assigns(socket, %{id: id}, %Actions.Read{} = action, %Options{} = options) do
    socket
    |> assign(:id, "#{id}-details")
    |> assign(:fields, visible_fields(socket, options.details_fields, action, options))
  end

  defp do_prepare_assigns(socket, %{id: nil}, %Actions.Create{}, %Options{} = options) do
    socket
    |> assign(:id, "#{Ash.Resource.Info.trace_name(options.resource)}-create")
  end

  defp do_prepare_assigns(socket, %{id: id}, %type{}, %Options{})
       when type in [Actions.Update, Actions.Destroy] do
    socket
    |> assign(:id, "#{id}-form")
  end

  # What a record a list column names links to, the way the details page
  # links it: one `AshQuick.Nav.Info.details_linker/3` over the resources the
  # columns name, asked of every cell. Built again it is an equal function,
  # so a navigation that changes neither the scope nor the routes leaves the
  # rows untouched.
  defp list_linker(socket, %Options{} = options) do
    options.resource
    |> DetailsUtils.linked_records(options.list_fields)
    |> Enum.map(&elem(&1, 1))
    |> AshQuick.Nav.Info.details_linker(socket.assigns[:scope])
  end

  # A column every row would show as hidden is left out instead. Recomputed per
  # navigation, but the answer only changes with the scope, so the assign is
  # only marked changed when it does.
  defp visible_fields(socket, fields, action, %Options{resource: resource}) do
    AshQuick.LiveView.Utils.visible_fields(fields, resource, action, socket.assigns[:scope])
  end

  # Public only because the generated `handle_params/3` calls it.
  #
  # A patch to a URL this page cannot serve leaves the page it came from. The
  # hooks that page attached would otherwise stay: a list's refetch already
  # scheduled would read through an action that is now nil and crash the view,
  # and its events would act on a selection the not-found page does not show.
  # So the page's own events and messages are dropped here, as the form drops
  # the page under it, and the selection goes with the page. Anything else is
  # the host's and goes on.
  def leave_page(socket) do
    page_events = ListUtils.events() ++ DetailsUtils.events() ++ FormUtils.events()

    socket
    |> Phoenix.LiveView.detach_hook(:quick_view_events_hook, :handle_event)
    |> Phoenix.LiveView.attach_hook(:quick_view_events_hook, :handle_event, fn
      event, _params, socket ->
        if event in page_events, do: {:halt, socket}, else: {:cont, socket}
    end)
    |> Phoenix.LiveView.detach_hook(:quick_view_info_hook, :handle_info)
    |> Phoenix.LiveView.attach_hook(:quick_view_info_hook, :handle_info, fn
      {:refetch, _assign, _info}, socket -> {:halt, socket}
      %{payload: %AshQuick.PubSub.Notice{}}, socket -> {:halt, socket}
      _message, socket -> {:cont, socket}
    end)
    |> assign(selected_rows: %{}, row_actions: nil)
  end
end
