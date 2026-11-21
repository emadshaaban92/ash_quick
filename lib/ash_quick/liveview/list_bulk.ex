defmodule AshQuick.LiveView.ListBulk do
  @moduledoc false
  # The list's bulk actions: opened over the list for the ticked rows, their
  # form, the run, and what the flash says of rows it did not write.
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]
  use Gettext, backend: AshQuick.Gettext

  alias Ash.Resource.Actions
  alias AshQuick.Labels
  alias AshQuick.LiveView.ActionErrors
  alias AshQuick.LiveView.BulkActions
  alias AshQuick.LiveView.BulkForm
  alias AshQuick.LiveView.DownloadUtils
  alias AshQuick.LiveView.FieldErrors
  alias AshQuick.LiveView.FormParams
  alias AshQuick.LiveView.ListRead
  alias AshQuick.LiveView.ListRows
  alias AshQuick.LiveView.ListUtils
  alias AshQuick.LiveView.Liveness
  alias AshQuick.LiveView.PrintUtils
  alias AshQuick.LiveView.Utils

  @error_classes [Ash.Error.Invalid, Ash.Error.Forbidden, Ash.Error.Framework, Ash.Error.Unknown]

  def handle_list_events("bulk_action", %{"action_name" => action_name}, socket, options) do
    case BulkActions.offered(socket.assigns[:bulk_actions], options.resource, action_name) do
      nil -> {:halt, refuse_bulk_action(socket)}
      action -> {:halt, open_bulk_action(action, socket, options)}
    end
  end

  # Nothing to validate or run: no bulk action is open, so the event was forged.
  def handle_list_events(event, _params, %{assigns: %{ash_quick_bulk: nil}} = socket, _options)
      when event in ["bulk_validate", "bulk_save"] do
    {:halt, ListUtils.refuse_action(socket)}
  end

  # A confirmation, or a form whose only inputs a field policy hides, posts
  # nothing.
  def handle_list_events(event, params, socket, options)
      when event in ["bulk_validate", "bulk_save"] and not is_map_key(params, "form") do
    handle_list_events(event, Map.put(params, "form", %{}), socket, options)
  end

  def handle_list_events("bulk_validate", %{"form" => params} = event, socket, _options) do
    {:halt, update_bulk_form(socket, params, event["_target"])}
  end

  def handle_list_events("bulk_save", %{"form" => params}, socket, options) do
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

  def handle_list_events("bulk_close", _params, socket, _options) do
    {:halt, assign(socket, :ash_quick_bulk, nil)}
  end

  def handle_list_events(_, _, socket, _options), do: {:cont, socket}

  # Opened over the list rather than at a URL of its own: a patch would reset
  # the selection it is about to act on. Who may run it is left to the run,
  # which asks of each selected row: asked here of no row, a policy that only
  # a row can answer would refuse a selection it allows.
  #
  # A refused open closes whatever bulk action was open before it, so no later
  # event runs one the page no longer shows.
  defp open_bulk_action(action, socket, options) do
    if ListUtils.selected_records(socket) == [] do
      refuse_bulk_action(socket)
    else
      scope = socket.assigns.scope

      form =
        if Utils.action_fields(options.resource, action.name, scope) != [],
          do: BulkForm.new(options.resource, action, scope)

      # Inputs it takes, every one hidden from the actor: nothing left that
      # they may set, and a confirmation would run it over values they never
      # saw.
      if form && Utils.form_fields(form, scope) == [] do
        refuse_bulk_action(socket)
      else
        assign(socket, :ash_quick_bulk, %{action: action, form: form})
      end
    end
  end

  defp refuse_bulk_action(socket),
    do: socket |> assign(:ash_quick_bulk, nil) |> ListUtils.refuse_action()

  defp update_bulk_form(socket, params, target) do
    case socket.assigns.ash_quick_bulk do
      %{form: %AshPhoenix.Form{} = form, action: action} = bulk ->
        params =
          params
          |> FieldErrors.mark_used(target)
          |> FormParams.put_emptied_selections()
          |> FormParams.maybe_put_has_many(form)

        assign(socket, :ash_quick_bulk, %{bulk | form: BulkForm.validate(form, params, action)})

      _confirmation ->
        socket
    end
  end

  defp run_bulk_action(%{action: action}, input, socket, options) do
    selected = ListUtils.selected_ids(socket)
    records = ListUtils.selected_records(socket)

    result =
      records |> timed_bulk_run(action, input, socket, options) |> in_selection_order(records)

    socket = socket |> PrintUtils.print(result) |> DownloadUtils.deliver(result)

    case result do
      # `transaction: :all` rolled every row back, so the modal stays as it was
      # for the values to be corrected or the run abandoned.
      %{status: :error, errors: errors} ->
        put_flash(socket, :error, bulk_error_message(errors, options.resource))

      # A bulk write that matches no row (a stale one, say) is not an error, so
      # `:success` does not mean every selected row was written. The records it
      # returns are the ones that were; the rest are reported and kept selected.
      %{records: written} ->
        written_ids = Enum.map(written || [], & &1.id)
        skipped_ids = selected -- written_ids
        data = ListRead.load_data!(socket, socket.assigns.params, options)
        shown = MapSet.new(data.results, & &1.id)

        socket
        |> assign(:ash_quick_bulk, nil)
        # The reader's own run, so the list closes up: a queue it worked
        # through empties, and the rows after it move up.
        |> assign(data: data)
        |> assign(ListRows.fresh_screen(data))
        |> assign(
          selected_rows:
            Map.take(socket.assigns.selected_rows, Enum.filter(skipped_ids, &(&1 in shown)))
        )
        |> report_skipped_rows({options.resource, action}, length(selected), skipped_ids)
        |> Liveness.resync(:data, options)
        |> ListUtils.refresh_row_actions(options)
    end
  end

  # A bulk result holds an error class per failed batch. Unwrapped into one
  # class, the errors inside are what `ActionErrors` words; left wrapped, a
  # class inside a class reads as an error of ours.
  defp bulk_error_message([_ | _] = errors, resource) do
    errors
    |> Enum.flat_map(fn
      %class{errors: [_ | _] = inner} when class in @error_classes -> inner
      error -> [error]
    end)
    |> Ash.Error.to_error_class()
    |> ActionErrors.user_facing_message(resource)
  end

  defp bulk_error_message(_no_errors, _resource), do: ActionErrors.generic_message()

  # Timed as `[:ash_quick, :bulk, :run]` (see `AshQuick.Telemetry`).
  defp timed_bulk_run(records, action, input, socket, options) do
    AshQuick.Telemetry.span(
      [:bulk, :run],
      %{
        quick_view: socket.view,
        resource: options.resource,
        action: action.name,
        type: action.type,
        scope: socket.assigns.scope,
        selected: length(records)
      },
      fn ->
        result = bulk_run(records, action, input, socket)
        {result, %{written: written(result)}, %{status: result.status}}
      end
    )
  end

  # `transaction: :all` rolls a run that did not succeed back whole, so it
  # wrote nothing, whatever records it hands back.
  defp written(%Ash.BulkResult{status: :success, records: records}), do: length(records || [])
  defp written(_rolled_back), do: 0

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
      # A write that names an actor is authorized under every domain
      # `authorize` setting, and a `use AshQuick.Scope` scope always names one,
      # even `nil`. A host scope with its own `Ash.Scope.ToOpts` may name none,
      # and a `:when_requested` domain then skips authorization. The run's
      # policy, not the menu, is what refuses a forged bulk event, so it asks.
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

  # With nothing applied there is no "other" row to speak of, so the flash says
  # the action did not go through at all.
  defp skipped_rows_message({resource, action}, selected, selected) do
    ngettext(
      "%{action} was not applied. The selected row was not changed and is still selected: check it and try again.",
      "%{action} was not applied. The %{count} selected rows were not changed and are still selected: check them and try again.",
      selected,
      action: Labels.name(action.name, resource)
    )
  end

  defp skipped_rows_message({resource, action}, selected, skipped) do
    applied =
      ngettext(
        "%{action} applied to %{applied} of 1 selected row.",
        "%{action} applied to %{applied} of %{count} selected rows.",
        selected,
        action: Labels.name(action.name, resource),
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
end
