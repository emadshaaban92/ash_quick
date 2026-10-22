defmodule AshQuick.LiveView.ListUtils do
  @moduledoc false
  require Ash.Query
  require Logger
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 2, assign: 3]
  use Gettext, backend: AshQuick.Gettext

  alias Ash.Resource.Actions
  alias AshQuick.LiveView.ActionErrors
  alias AshQuick.LiveView.BulkActions
  alias AshQuick.LiveView.BulkForm
  alias AshQuick.LiveView.FieldErrors
  alias AshQuick.LiveView.FormUtils
  alias AshQuick.LiveView.URLParams
  alias AshQuick.LiveView.CustomFilter
  alias AshQuick.LiveView.Components.FilterForm
  alias AshQuick.LiveView.Liveness
  alias AshQuick.LiveView.PrintUtils
  alias AshQuick.LiveView.Utils
  alias AshQuick.LiveView.QuickView.Options

  # Names no field, because the field is not always the part that was wrong —
  # an unusable value on a perfectly good field lands here too. A visitor who
  # typed the filter knows which one they typed, and a visitor who was handed
  # the link cannot act on the name either way.
  defp refused_filter_message,
    do: gettext("That filter couldn't be applied to this list, so it was ignored.")

  @error_classes [Ash.Error.Invalid, Ash.Error.Forbidden, Ash.Error.Framework, Ash.Error.Unknown]

  def do_handle_params(
        socket,
        %URLParams{} = params,
        %Actions.Read{get?: false} = action,
        %Options{} = options
      ) do
    {socket, params} = drop_hidden_fields(socket, params, action, options)
    {socket, params, page} = initial_read(socket, params, options)

    socket
    |> assign(:params, params)
    |> assign(:selected_rows, %{})
    |> assign(:export_data, nil)
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
      [initial: page] ++ Liveness.list_options(options)
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
    |> apply_sort(params, options)
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

  # A row on a field a field policy hides from the actor on every record is
  # dropped before the read, the way `FilterForm` leaves the field out: Ash
  # would read the field as `nil`, so the list would come back empty under a
  # filter that looked like an answer. Only a link carries one, written for an
  # actor who could see the field or by hand, so the visitor is told, and the
  # address bar is corrected with the rest of `:params`.
  #
  # A root that is itself such a row, as a hand-written link can be, leaves no
  # filter at all.
  defp drop_hidden_fields(socket, %URLParams{custom_filter: nil} = params, _action, _options),
    do: {socket, params}

  defp drop_hidden_fields(socket, %URLParams{custom_filter: filter} = params, action, options) do
    case hidden_fields(filter, action, options.resource, socket.assigns[:scope]) do
      [] ->
        {socket, params}

      hidden ->
        filter = CustomFilter.reject_fields(filter, hidden)

        {put_flash(socket, :error, refused_filter_message()),
         %URLParams{params | custom_filter: filter}}
    end
  end

  # The names `filter` uses that are fields of `resource` the actor may not
  # see. A name that is no field is left to the read, which refuses it.
  defp hidden_fields(filter, action, resource, scope) do
    by_name =
      resource
      |> Ash.Resource.Info.fields([:attributes, :calculations, :aggregates])
      |> Map.new(&{to_string(&1.name), &1.name})

    named = filter |> CustomFilter.field_names() |> Enum.filter(&Map.has_key?(by_name, &1))
    visible = named |> Enum.map(&by_name[&1]) |> Utils.visible_fields(resource, action, scope)

    Enum.reject(named, &(by_name[&1] in visible))
  end

  # A custom filter is the one part of this query a visitor authors, and there
  # is no asking in advance whether it works. It can fail in two places and
  # nothing before the read sees either:
  #
  #   * a `field_name` the resource does not have — `from_string/1` decodes it
  #     as written, knowing no resource, and `filter_input/2` invalidates the
  #     query;
  #   * a real field carrying a value its type cannot cast — which
  #     `filter_input/2` accepts, and the *data layer* refuses, as an
  #     `Ecto.Query.CastError`. `equals` on a UUID, a price or a date is a
  #     free-text box in `FilterForm`, so this one is reachable by typing, not
  #     only by editing a URL.
  #
  # Both arrive the same way: raised by `Ash.read!` from inside
  # `handle_params/3`, taking the mount down rather than showing on the page.
  # A validity pre-check answers only the first and would have to keep in step
  # with everything the data layer will accept, so the filter is not validated
  # here — it is tried.
  #
  # A read that raises with a filter applied is read once more without it. If
  # that succeeds the filter was the problem: it is dropped from the params the
  # whole page is built from, with a flash saying so, and the list, the export
  # query, the filter form and `full_path/2` all follow. If it raises too, the
  # filter was never the problem and that error stands — `base_filter`,
  # `filters` and `sort_by` are the host's own, and a bug in one should keep
  # raising loudly rather than become a flash a visitor can do nothing about.
  #
  # Only the first of those two is recognisable. An uncastable value reaches us
  # as an `Ash.Error.Unknown` whose `:error` is the data layer's
  # `Ecto.Query.CastError` already rendered to a string — the same struct a bug
  # in the read produces, so there is nothing to tell them apart. What the
  # rescue can say is that the error came from the read at all:
  # `ash_error?/1` lets a raise out of `load_data!/3`'s own pipeline keep
  # raising instead of being reported as the visitor's filter.
  #
  # Rescued either way means the flash can be wrong — a read that fails once and
  # succeeds on the retry gets it too — so the error is logged before the retry.
  #
  # The page is handed to `keep_live/4` as `:initial`, so this is the render's
  # one read rather than a probe in front of another one. Refetches re-run the
  # closure below, which closes over the corrected params.
  defp initial_read(socket, %URLParams{custom_filter: nil} = params, %Options{} = options),
    do: {socket, params, load_data!(socket, params, options)}

  defp initial_read(socket, %URLParams{} = params, %Options{} = options) do
    {socket, params, load_data!(socket, params, options)}
  rescue
    error ->
      if Ash.Error.ash_error?(error) do
        retry_without_filter(socket, params, options, error)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp retry_without_filter(socket, %URLParams{} = params, %Options{} = options, error) do
    # Never the filter's values: they are what the visitor typed (an email, a
    # name), and the data layer's cast error quotes them back, so each value is
    # redacted out of the messages. The start of a message stays, because it is
    # what tells a refused value from a host bug or a dropped connection; the
    # rest goes, because an error such as `InvalidFilterValue` goes on to
    # inspect the whole query, the actor and their email included. The field
    # names come from the URL too, so they are inspected, and a message is cut
    # to one line, or a newline in one would forge a log line. The frames are
    # each inner error's own: the rescue's trace is only where `Ash.read!`
    # re-raised, the same for every failure.
    values = CustomFilter.values(params.custom_filter)

    Logger.warning("""
    AshQuick is re-reading #{inspect(options.resource)} without the custom \
    filter the URL carried, which raised. The visitor will be told the filter \
    was refused, whether or not that is what this error means.

    Filtered fields: #{Enum.map_join(CustomFilter.field_names(params.custom_filter), ", ", &inspect/1)}
    Errors:

    #{Enum.map_join(inner_errors(error), "\n", &raised_at(&1, values))}\
    """)

    params = %URLParams{params | custom_filter: nil}

    {put_flash(socket, :error, refused_filter_message()), params,
     load_data!(socket, params, options)}
  end

  defp inner_errors(error) do
    case Ash.Error.to_error_class(error) do
      %{errors: [_ | _] = errors} -> errors
      class -> [class]
    end
  end

  @message_length 160

  defp raised_at(error, values) do
    "#{inspect(error.__struct__)}: #{summary(error, values)}\n#{frames(error)}"
  end

  # The message without Ash's bread crumbs, values redacted, on one line and cut
  # short of whatever context the error inspects after it.
  defp summary(error, values) do
    summary =
      error
      |> Exception.message()
      |> redact(values)
      |> String.split("\n")
      |> Enum.reject(&(String.trim(&1) in ["", "Bread Crumbs:"] or bread_crumb?(&1)))
      |> Enum.join(" ")

    if String.length(summary) > @message_length,
      do: String.slice(summary, 0, @message_length) <> "…",
      else: summary
  end

  defp bread_crumb?(line), do: String.starts_with?(String.trim_leading(line), "> ")

  defp frames(%{stacktrace: %{stacktrace: [_ | _] = frames}}),
    do: Exception.format_stacktrace(frames)

  defp frames(_error), do: "    (no stack trace)\n"

  @redacted "[filter value]"

  # Quoted wherever it appears; bare only from four characters up, below which
  # it would be cut out of words and numbers the message needs. A value that
  # short identifies no one.
  defp redact(message, values) do
    Enum.reduce(values, message, fn value, message ->
      message = String.replace(message, inspect(value), @redacted)

      if String.length(value) >= 4,
        do: String.replace(message, value, @redacted),
        else: message
    end)
  end

  # A column the visitor sorted by goes first, then the QuickView's `sort_by`,
  # then the action's own sort, each ordering the rows the one before ties on;
  # Ash ends every paginated read with the primary key, so ties left after all
  # of them keep their order across pages. The column goes through
  # `sort_input/3`, as a visitor's input: Ash refuses a private field there,
  # and authorizes it against field policies. Prepending it shifts the indices
  # Ash keeps of input sorts, so `sort_by` is not authorized as one.
  defp apply_sort(query, %URLParams{} = params, %Options{} = options) do
    query = maybe_apply_sort(query, options.sort_by)

    case URLParams.sort_input(params) do
      nil -> query
      sort -> Ash.Query.sort_input(query, sort, prepend?: true)
    end
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
    |> apply_sort(params, options)
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

  defp handle_list_events("page_size", %{"limit" => limit}, socket, _options) do
    params = URLParams.change_limit(socket.assigns.params, limit)

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
          socket |> put_flash(:error, gettext("Unable to determine current user for export"))
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

  defp handle_list_events("bulk_action", %{"action_name" => action_name}, socket, options) do
    case BulkActions.offered(socket.assigns[:bulk_actions], options.resource, action_name) do
      nil -> {:halt, refuse_action(socket)}
      action -> {:halt, open_bulk_action(action, socket, options)}
    end
  end

  # Nothing to validate or run: no bulk action is open, so the event was forged.
  defp handle_list_events(event, _params, %{assigns: %{ash_quick_bulk: nil}} = socket, _options)
       when event in ["bulk_validate", "bulk_save"] do
    {:halt, refuse_action(socket)}
  end

  # A confirmation, or a form whose only inputs a field policy hides, posts
  # nothing.
  defp handle_list_events(event, params, socket, options)
       when event in ["bulk_validate", "bulk_save"] and not is_map_key(params, "form") do
    handle_list_events(event, Map.put(params, "form", %{}), socket, options)
  end

  defp handle_list_events("bulk_validate", %{"form" => params} = event, socket, _options) do
    {:halt, update_bulk_form(socket, params, event["_target"])}
  end

  defp handle_list_events("bulk_save", %{"form" => params}, socket, options) do
    socket = update_bulk_form(socket, params, nil)

    case socket.assigns.ash_quick_bulk do
      %{form: %AshPhoenix.Form{} = form} = bulk ->
        if BulkForm.valid?(form),
          do:
            {:halt,
             run_bulk_action(
               bulk,
               BulkForm.input(form, options.resource, bulk.action),
               socket,
               options
             )},
          else: {:halt, socket}

      bulk ->
        {:halt, run_bulk_action(bulk, %{}, socket, options)}
    end
  end

  defp handle_list_events("bulk_close", _params, socket, _options) do
    {:halt, assign(socket, :ash_quick_bulk, nil)}
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

  # Opened over the list rather than at a URL of its own: a patch would reset
  # the selection it is about to act on. Who may run it is left to the run,
  # which asks of each selected row: asked here of no row, a policy that only
  # a row can answer would refuse a selection it allows.
  defp open_bulk_action(action, socket, options) do
    if selected_records(socket) == [] do
      refuse_action(socket)
    else
      scope = socket.assigns.scope

      form =
        if Utils.action_fields(options.resource, action.name, scope) != [],
          do: BulkForm.new(options.resource, action, scope)

      assign(socket, :ash_quick_bulk, %{action: action, form: form})
    end
  end

  defp update_bulk_form(socket, params, target) do
    case socket.assigns.ash_quick_bulk do
      %{form: %AshPhoenix.Form{} = form, action: action} = bulk ->
        params =
          params
          |> FieldErrors.mark_used(target)
          |> FormUtils.put_emptied_selections()
          |> FormUtils.maybe_put_has_many(form)

        assign(socket, :ash_quick_bulk, %{bulk | form: BulkForm.validate(form, params, action)})

      _confirmation ->
        socket
    end
  end

  defp selected_ids(socket) do
    for {id, "on"} <- socket.assigns.selected_rows, id != "all", do: id
  end

  # Only rows the list is showing, read through the actor's scope: a selected id
  # that is not among them is one the actor cannot read, or one that has left
  # the list since it was ticked.
  defp selected_records(socket) do
    selected = selected_ids(socket)
    Enum.filter(socket.assigns.data.results, &(&1.id in selected))
  end

  defp run_bulk_action(%{action: action}, input, socket, options) do
    selected = selected_ids(socket)
    records = selected_records(socket)

    result = records |> bulk_run(action, input, socket) |> in_selection_order(records)
    socket = PrintUtils.print(socket, result)

    case result do
      # `transaction: :all` rolled every row back, so the modal stays as it was
      # for the values to be corrected or the run abandoned.
      %{status: :error, errors: errors} ->
        put_flash(socket, :error, bulk_error_message(errors))

      # A bulk write that matches no row (a stale one, say) is not an error, so
      # `:success` does not mean every selected row was written. The records it
      # returns are the ones that were; the rest are reported and kept selected.
      %{records: written} ->
        skipped_ids = selected -- Enum.map(written || [], & &1.id)
        data = load_data!(socket, socket.assigns.params, options)
        shown = MapSet.new(data.results, & &1.id)

        socket
        |> assign(:ash_quick_bulk, nil)
        |> assign(data: data)
        |> assign(
          selected_rows:
            Map.take(socket.assigns.selected_rows, Enum.filter(skipped_ids, &(&1 in shown)))
        )
        |> report_skipped_rows(action, length(selected), skipped_ids)
        |> Liveness.resync(:data, options)
        |> refresh_row_actions(options)
    end
  end

  # A bulk result holds an error class per failed batch. Unwrapped into one
  # class, the errors inside are what `ActionErrors` words; left wrapped, a
  # class inside a class reads as an error of ours.
  defp bulk_error_message([_ | _] = errors) do
    errors
    |> Enum.flat_map(fn
      %class{errors: [_ | _] = inner} when class in @error_classes -> inner
      error -> [error]
    end)
    |> Ash.Error.to_error_class()
    |> ActionErrors.user_facing_message()
  end

  defp bulk_error_message(_no_errors), do: ActionErrors.generic_message()

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

  defp refuse_action(socket) do
    socket |> put_flash(:error, AshQuick.LiveView.ActionErrors.forbidden_message())
  end

  # Stamped as every other run is, whatever surface offered it: a policy scoped
  # to `:ash_quick_list_bulk` decides what the menu shows, not what runs.
  defp bulk_run(records, %Actions.Update{} = action, input, socket) do
    Ash.bulk_update(records, action.name, input, bulk_opts(socket))
  end

  defp bulk_run(records, %Actions.Destroy{} = action, input, socket) do
    Ash.bulk_destroy(records, action.name, input, bulk_opts(socket))
  end

  defp bulk_opts(socket) do
    [
      scope: socket.assigns.scope,
      context: %{
        :action_source => AshQuick.form_source(),
        AshQuick.form_stage_key() => AshQuick.form_submit_stage()
      },
      # We shouldn't need this, but it seems to be required for some reason
      authorize?: true,
      strategy: :stream,
      transaction: :all,
      stop_on_error?: true,
      return_records?: true,
      # A refused run is worded for the person who asked for it, which needs
      # the error that refused it.
      return_errors?: true,
      # One publication per row written, so a page holding a row hears about a
      # bulk write as it does a row action's. A batch that errors is rolled back
      # whole by `transaction: :all` and publishes nothing, so nothing is
      # announced that was then undone.
      notify?: true
    ]
  end

  # A print's pages follow the rows as the list showed them, whatever order the
  # bulk run hands its records back in.
  defp in_selection_order(%Ash.BulkResult{records: [_ | _] = written} = result, records) do
    position =
      records |> Enum.with_index() |> Map.new(fn {record, index} -> {record.id, index} end)

    %{result | records: Enum.sort_by(written, &position[&1.id])}
  end

  defp in_selection_order(result, _records), do: result

  defp report_skipped_rows(socket, _action, _selected, []), do: socket

  defp report_skipped_rows(socket, action, selected, skipped_ids) do
    put_flash(socket, :error, skipped_rows_message(action, selected, length(skipped_ids)))
  end

  defp skipped_rows_message(action, selected, skipped) do
    applied =
      ngettext(
        "%{action} applied to %{applied} of 1 selected row.",
        "%{action} applied to %{applied} of %{count} selected rows.",
        selected,
        action: Utils.humanize(action.name),
        applied: selected - skipped
      )

    not_changed =
      ngettext(
        "The other row was not changed and is still selected: check it and try again.",
        "The other %{count} rows were not changed and are still selected: check them and try again.",
        skipped
      )

    applied <> " " <> not_changed
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
    resource
    |> Utils.record_actions()
    |> Utils.reject_redundant_activation(record)
    |> Enum.filter(&AshQuick.can?({record, &1}, scope, :ash_quick_list))
  end
end
