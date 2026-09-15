defmodule AshQuick.LiveView.ListUtils do
  @moduledoc false
  require Ash.Query
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 2, assign: 3]
  alias Phoenix.LiveView.JS

  alias Ash.Resource.Actions
  alias AshQuick.LiveView.URLParams
  alias AshQuick.LiveView.CustomFilter
  alias AshQuick.LiveView.Components.FilterForm
  alias AshQuick.LiveView.Liveness
  alias AshQuick.LiveView.Utils
  alias AshQuick.LiveView.QuickView.Options

  # Names no field, because the field it named is the part that was wrong: a
  # visitor who edited a filter URL by hand knows which one, and a visitor who
  # was handed the link cannot act on the name either way.
  @refused_filter_message "That filter doesn't apply to this list, so it was ignored."

  def do_handle_params(
        socket,
        %URLParams{} = params,
        %Actions.Read{get?: false} = _action,
        %Options{} = options
      ) do
    {socket, params} = drop_refused_custom_filter(socket, params, options)

    socket
    |> assign(:params, params)
    |> assign(:selected_rows, %{})
    |> assign(:export_data, nil)
    |> assign(:print_data, nil)
    |> assign(:row_actions, nil)
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
      &load_data!(&1, params, options),
      Liveness.list_options(options)
    )
  end

  defp set_title(socket, %{resource: resource}) do
    title =
      case Ash.Resource.Info.plural_name(resource) do
        nil -> "#{Ash.Resource.Info.short_name(resource)}s" |> Utils.humanize()
        name -> name |> Utils.humanize()
      end

    socket |> assign(page_title: title)
  end

  def load_data!(socket, %URLParams{} = params, %Options{} = options) do
    limit = params.limit
    offset = get_offset(params.page, limit)

    options.resource
    |> Ash.Query.for_read(
      socket.assigns.ash_action.name,
      Utils.lookup_input(options.resource, params.search),
      scope: socket.assigns.scope
    )
    |> maybe_apply_base_filter(options.base_filter)
    |> maybe_apply_filters(options.filters, params.selected_filters)
    |> maybe_apply_custom_filter(params.custom_filter)
    |> maybe_apply_sort(options.sort_by)
    |> Utils.load_fields(options.list_fields, strict?: true)
    |> Ash.Query.load(options.load ++ options.list_load, strict?: true)
    |> maybe_load_active(options.resource)
    |> Ash.Query.page(limit: limit, offset: offset)
    |> Ash.read!()
  end

  defp maybe_apply_base_filter(query, nil), do: query
  defp maybe_apply_base_filter(query, base_filter), do: Ash.Query.filter(query, ^base_filter)

  defp maybe_apply_filters(query, _, []), do: query

  defp maybe_apply_filters(query, filters, [filter_name | rest]) do
    case Enum.find(filters, &(&1["name"] == filter_name)) do
      %{"expression" => expression} -> Ash.Query.filter(query, ^expression)
      _ -> query
    end
    |> maybe_apply_filters(filters, rest)
  end

  defp maybe_apply_custom_filter(query, nil), do: query

  defp maybe_apply_custom_filter(query, custom_filter) do
    case CustomFilter.build_ash_filter(custom_filter) do
      nil -> query
      ash_filter -> Ash.Query.filter_input(query, ash_filter)
    end
  end

  # The one part of this query the URL can be wrong about in a way nothing
  # before the read can catch. `CustomFilter.from_string/1` decodes
  # `field_name` as written — it is handed no resource, so it cannot tell a
  # real field from an invented one, the same reason `parse_action/1` carries
  # an unknown action name through. The difference is the refusal: an unknown
  # action renders as not found, while an unknown field reaches
  # `filter_input/2`, invalidates the query, and is raised by `Ash.read!` from
  # inside `handle_params/3` — which takes the mount down rather than showing
  # up on the page.
  #
  # So the resource is asked before the read, and a filter it refuses is
  # dropped from the params the whole page is built from: the list reads
  # unfiltered, `build_export_query/4` builds the same query, the filter form
  # opens empty, and `full_path/2` stops writing a filter nothing applied.
  #
  # Only the custom filter is treated this way. `base_filter`, `filters` and
  # `sort_by` are the host's own, and a query error in one of those is a bug
  # that should keep raising loudly rather than becoming a flash the visitor
  # can do nothing about.
  defp drop_refused_custom_filter(socket, %URLParams{custom_filter: nil} = params, _options),
    do: {socket, params}

  defp drop_refused_custom_filter(socket, %URLParams{} = params, %Options{} = options) do
    if custom_filter_refused?(options.resource, params.custom_filter) do
      {put_flash(socket, :error, @refused_filter_message),
       %URLParams{params | custom_filter: nil}}
    else
      {socket, params}
    end
  end

  # Asked through `maybe_apply_custom_filter/2` rather than beside it, so what
  # is validated here cannot drift from what the read applies. Nothing is
  # fetched: `filter_input/2` resolves the field names against the resource and
  # records what it cannot resolve, which is the whole question.
  defp custom_filter_refused?(resource, custom_filter) do
    resource
    |> Ash.Query.new()
    |> maybe_apply_custom_filter(custom_filter)
    |> then(&(not &1.valid?))
  end

  defp maybe_apply_sort(query, nil), do: query
  defp maybe_apply_sort(query, sort_by), do: Ash.Query.sort(query, sort_by, prepend?: true)

  defp build_export_query(resource, [], socket, options) do
    params = socket.assigns.params

    resource
    |> Ash.Query.for_read(
      socket.assigns.ash_action.name,
      Utils.lookup_input(resource, params.search),
      scope: socket.assigns.scope
    )
    |> maybe_apply_base_filter(options.base_filter)
    |> maybe_apply_filters(options.filters, params.selected_filters)
    |> maybe_apply_custom_filter(params.custom_filter)
    |> maybe_apply_sort(options.sort_by)
  end

  defp build_export_query(resource, ids, socket, _options) do
    resource
    |> Ash.Query.for_read(socket.assigns.ash_action.name, %{}, scope: socket.assigns.scope)
    |> Ash.Query.filter(id in ^ids)
  end

  defp maybe_load_active(query, resource) do
    case AshQuick.Info.activation(resource) do
      nil -> query
      %{attribute: attribute} -> Ash.Query.load(query, attribute, strict?: true)
    end
  end

  def get_offset(nil, _), do: 0
  def get_offset(page, limit), do: (page - 1) * limit

  defp handle_list_events("search", %{"search" => search}, socket, _options) do
    params =
      socket.assigns.params
      |> URLParams.change_search(search)

    {:halt, push_patch(socket, to: URLParams.full_path(socket.assigns.path, params))}
  end

  defp handle_list_events("new_click", _, socket, _) do
    params =
      socket.assigns.params
      |> URLParams.to_action_params(:create)

    {:halt, push_patch(socket, to: URLParams.full_path(socket.assigns.path, params))}
  end

  defp handle_list_events("export", %{"format" => format}, socket, options) do
    selected_ids =
      socket.assigns.selected_rows
      |> Map.drop(["all"])
      |> Enum.filter(fn {_k, v} -> v == "on" end)
      |> Enum.map(fn {k, _v} -> k end)

    export_query =
      options.resource
      |> build_export_query(selected_ids, socket, options)
      |> Utils.load_fields(options.export_fields, strict?: true)

    socket =
      case Ash.Scope.ToOpts.get_actor(socket.assigns.scope) do
        {:ok, actor} when not is_nil(actor) ->
          socket
          |> assign_async(:export_data, fn ->
            {:ok, url} =
              AshQuick.LiveView.ExportUtils.generate_export_url(
                export_query,
                actor,
                options,
                format |> String.to_existing_atom()
              )

            {:ok, %{export_data: %{url: url}}}
          end)

        _ ->
          socket |> put_flash(:error, "Unable to determine current user for export")
      end

    {:halt, socket}
  end

  defp handle_list_events("close-export-modal", _, socket, _) do
    socket =
      socket
      |> cancel_async(socket.assigns.export_data)
      |> assign(export_data: nil)

    {:halt, socket}
  end

  defp handle_list_events(
         "print_pdf",
         %{"template_index" => template_index},
         socket,
         options
       ) do
    selected_ids =
      socket.assigns.selected_rows
      |> Map.drop(["all"])
      |> Enum.filter(fn {_k, v} -> v == "on" end)
      |> Enum.map(fn {k, _v} -> k end)

    scope = socket.assigns.scope

    template_module = Enum.at(options.print_templates, template_index)

    socket =
      case Ash.Scope.ToOpts.get_actor(scope) do
        {:ok, actor} when not is_nil(actor) ->
          socket
          |> assign_async(:print_data, fn ->
            {:ok, url} =
              AshQuick.LiveView.PrintUtils.generate_print_url(
                selected_ids,
                actor,
                scope,
                template_module,
                options.resource
              )

            {:ok, %{print_data: %{url: url}}}
          end)

        _ ->
          socket |> put_flash(:error, "Unable to determine current user for printing")
      end

    {:halt, socket}
  end

  defp handle_list_events("close-print-modal", _, socket, _) do
    socket =
      socket
      |> cancel_async(socket.assigns.print_data)
      |> assign(print_data: nil)

    {:halt, socket}
  end

  defp handle_list_events("bulk_action", %{"action_name" => action_name}, socket, options) do
    selected_ids = socket.assigns.selected_rows |> Map.keys()

    records = socket.assigns.data.results |> Enum.filter(&(&1.id in selected_ids))

    action_atom = String.to_existing_atom(action_name)
    action = Ash.Resource.Info.action(options.resource, action_atom)

    socket =
      case run_bulk_action(records, action, socket) do
        %{status: :error, errors: [%{errors: [%{message: message}]}]} ->
          socket |> put_flash(:error, message)

        %{status: :error, errors: errors} ->
          socket |> put_flash(:error, errors |> Ash.Error.error_descriptions())

        %{status: :error} ->
          socket |> put_flash(:error, "Unknown Error")

        _ ->
          socket
          |> assign(data: load_data!(socket, socket.assigns.params, options))
          |> assign(selected_rows: %{})
          |> Liveness.resync(:data, options)
          |> refresh_row_actions(options)
      end

    {:halt, socket}
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
    action_atom = String.to_existing_atom(action_name)
    action = Ash.Resource.Info.action(options.resource, action_atom)
    action_inputs = Ash.Resource.Info.action_inputs(options.resource, action_atom)

    case action_inputs |> Enum.to_list() do
      [] ->
        {:halt, do_action(id, action, socket, options)}

      _ ->
        params =
          socket.assigns.params
          |> URLParams.to_action_params(action_name, id: id)

        {:halt, push_patch(socket, to: URLParams.full_path(socket.assigns.path, params))}
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

  defp handle_list_info(%{topic: topic, payload: %Ash.Notifier.Notification{}}, socket, _) do
    {:halt, AshPhoenix.LiveView.handle_live(socket, topic, :data)}
  end

  defp handle_list_info({:refetch, :data, refetch_info}, socket, _) do
    {:halt, AshPhoenix.LiveView.handle_live(socket, :refetch, :data, refetch_info)}
  end

  defp handle_list_info({FilterForm, custom_filter}, socket, _) do
    params =
      socket.assigns.params
      |> URLParams.change_custom_filter(custom_filter)

    {:halt, push_patch(socket, to: URLParams.full_path(socket.assigns.path, params))}
  end

  defp handle_list_info(_, socket, _options), do: {:cont, socket}

  defp do_action(id, action, socket, options) do
    case socket.assigns.data.results |> Enum.find(&(&1.id == id)) do
      nil -> refuse_action(socket)
      record -> run_and_reload(record, action, socket, options)
    end
  end

  # The list is read through the actor's scope, so an id that is not in it is
  # one the actor may not read (or that does not exist) — no row was drawn for
  # it. A hand-pushed event still names it: refuse rather than act on nil.
  defp refuse_action(socket) do
    socket |> put_flash(:error, AshQuick.LiveView.ActionErrors.forbidden_message())
  end

  defp run_and_reload(record, action, socket, options) do
    case run_action(record, action, socket) do
      {:error, error} ->
        socket |> put_flash(:error, AshQuick.LiveView.ActionErrors.user_facing_message(error))

      _ ->
        socket
        |> assign(data: load_data!(socket, socket.assigns.params, options))
        |> Liveness.resync(:data, options)
        |> refresh_row_actions(options)
    end
  end

  defp run_action(record, %Actions.Update{} = action, socket) do
    record
    |> Ash.update(
      action: action,
      scope: socket.assigns.scope,
      context: %{action_source: :ash_quick_list}
    )
  end

  defp run_action(record, %Actions.Destroy{} = action, socket) do
    record
    |> Ash.destroy(
      action: action,
      scope: socket.assigns.scope,
      context: %{action_source: :ash_quick_list}
    )
  end

  defp run_bulk_action(records, %Actions.Update{} = action, socket) do
    records
    |> Ash.bulk_update(action.name, %{},
      scope: socket.assigns.scope,
      context: %{action_source: :ash_quick_list_bulk},
      # We shouldn't need this, but it seems to be required for some reason
      authorize?: true,
      strategy: :stream,
      transaction: :all,
      stop_on_error?: true
      # For now notify seems to cause issues when the action fails
      # notify?: true
    )
  end

  defp run_bulk_action(records, %Actions.Destroy{} = action, socket) do
    records
    |> Ash.bulk_destroy(action.name, %{},
      scope: socket.assigns.scope,
      context: %{action_source: :ash_quick_list_bulk},
      # We shouldn't need this, but it seems to be required for some reason
      authorize?: true,
      strategy: :stream,
      transaction: :all,
      stop_on_error?: true,
      notify?: true
    )
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
  defp refresh_row_actions(socket, options) do
    case socket.assigns.row_actions do
      %{id: id} -> assign_row_actions(socket, id, options)
      nil -> socket
    end
  end

  defp record_actions(record, resource, scope) do
    actions = Ash.Resource.Info.actions(resource)

    actions
    |> Stream.filter(&(&1.type == :update))
    |> Utils.reject_redundant_activation(record)
    |> Enum.concat(Enum.filter(actions, &(&1.type == :destroy)))
    |> Enum.filter(&AshQuick.can?({record, &1}, scope, :ash_quick_list))
  end

  def resource_bulk_actions(resource, scope, _options) do
    actions =
      resource
      |> Ash.Resource.Info.actions()
      |> Stream.filter(&(&1.type == :update))
      |> Stream.filter(&(Ash.Resource.Info.action_inputs(resource, &1.name) |> Enum.empty?()))
      |> Enum.concat(Ash.Resource.Info.actions(resource) |> Enum.filter(&(&1.type == :destroy)))
      |> Enum.filter(&Ash.can?({resource, &1.name}, scope, log_policy_breakdown?: false))
      |> Enum.map(
        &%{
          title: &1.name |> Utils.humanize(),
          func: JS.push("bulk_action", value: %{"action_name" => &1.name |> to_string})
        }
      )

    actions
  end
end
