defmodule AshQuick.LiveView.DetailsUtils do
  @moduledoc false
  require Ash.Query
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 2]

  alias Ash.Resource.Actions
  alias AshQuick.LiveView.URLParams
  alias AshQuick.LiveView.Liveness
  alias AshQuick.LiveView.Utils
  alias AshQuick.LiveView.QuickView.Options

  def do_handle_params(
        socket,
        %URLParams{} = params,
        %Actions.Read{} = _action,
        %Options{} = options
      ) do
    socket
    |> assign(print_data: nil)
    |> detach_hook(:quick_view_events_hook, :handle_event)
    |> attach_hook(:quick_view_events_hook, :handle_event, fn
      event, params, socket -> handle_details_events(event, params, socket, options)
    end)
    |> detach_hook(:quick_view_info_hook, :handle_info)
    |> attach_hook(:quick_view_info_hook, :handle_info, fn
      message, socket -> handle_details_info(message, socket, options)
    end)
    |> detach_hook(:quick_view_async_hooks, :handle_async)
    |> attach_hook(:quick_view_async_hooks, :handle_async, fn
      _name, _result, socket -> {:cont, socket}
    end)
    |> AshPhoenix.LiveView.keep_live(
      :record,
      &load_record!(&1, params, options),
      Liveness.details_options(options, params)
    )
    |> set_title(options)
  end

  def load_record!(socket, %URLParams{id: id, read_args: read_args}, %Options{} = options) do
    options.resource
    |> Ash.Query.for_read(read_action_name(socket, options), read_args,
      scope: socket.assigns.scope
    )
    |> Ash.Query.filter(id == ^id)
    |> Utils.load_fields(options.details_fields, strict?: true)
    |> Ash.Query.load(options.load ++ options.details_load, strict?: true)
    |> Ash.Query.load(actor_load(options.resource), strict?: true)
    |> Utils.load_display_label()
    |> Ash.read_one()
    |> case do
      {:ok, record} -> record
      _ -> nil
    end
  end

  @doc false
  # What the details header's actor halves need loaded. The record carries a
  # foreign key and the header renders a name, so the relationships have to come
  # with it — nested down to the actor's label, because this load is strict and
  # an unlisted field on the actor would come back `NotLoaded`.
  #
  # Built from what the resource declared rather than from the two names: a
  # resource without `updated_by` has no such relationship, and naming it would
  # fail the whole read rather than drop half a header.
  #
  # This is deliberately the details query and not a global preparation on the
  # read action. The actor resource carries these fields itself, so a
  # preparation loading them would recurse through it; and every other read in
  # the app — lists, exports, relationship loads, the API — would pay for two
  # joins and the actor resource's read policies to render a header nobody is
  # looking at.
  def actor_load(resource) do
    case AshQuick.Config.actor_resource() do
      nil ->
        []

      actor ->
        label = AshQuick.Info.display_label(actor)
        resource |> AshQuick.Info.actor_fields() |> Enum.map(&{&1, [label]})
    end
  end

  # The details `keep_live(:record)` (and its refetch on a PubSub notification)
  # can outlive a patch to a create/update form, where `ash_action` is no longer
  # a read. Refetch with the current action only when it is a read; otherwise use
  # the configured details read action, so a stale refetch can never be built
  # against a non-read action.
  defp read_action_name(socket, options) do
    case socket.assigns.ash_action do
      %Actions.Read{name: name} -> name
      _ -> options.details_default_action
    end
  end

  defp set_title(socket, %{resource: resource}) do
    resource_name = Ash.Resource.Info.short_name(resource) |> Utils.humanize()

    title =
      case AshQuick.Info.display_value(socket.assigns.record) do
        nil -> resource_name
        label -> "#{resource_name} - #{label}"
      end

    socket |> assign(page_title: title)
  end

  defp handle_details_info(%{topic: topic, payload: %Ash.Notifier.Notification{}}, socket, _) do
    {:halt, AshPhoenix.LiveView.handle_live(socket, topic, :record)}
  end

  defp handle_details_info({:refetch, :record, refetch_info}, socket, _) do
    {:halt, AshPhoenix.LiveView.handle_live(socket, :refetch, :record, refetch_info)}
  end

  defp handle_details_info(_, socket, _options), do: {:cont, socket}

  defp handle_details_events(
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

        {:halt, push_patch(socket, to: URLParams.full_path(socket.assigns.base_path, params))}
    end
  end

  defp handle_details_events(
         "print_pdf",
         %{"template_index" => template_index},
         socket,
         options
       ) do
    record = socket.assigns.record
    scope = socket.assigns.scope

    template_module = Enum.at(options.print_templates, template_index)

    socket =
      case Ash.Scope.ToOpts.get_actor(scope) do
        {:ok, actor} when not is_nil(actor) ->
          socket
          |> assign_async(:print_data, fn ->
            {:ok, url} =
              AshQuick.LiveView.PrintUtils.generate_print_url(
                [record.id],
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

  defp handle_details_events("close-print-modal", _, socket, _) do
    socket =
      socket
      |> cancel_async(socket.assigns.print_data)
      |> assign(print_data: nil)

    {:halt, socket}
  end

  defp handle_details_events(_, _, socket, _options), do: {:cont, socket}

  # `load_record!/3` reads through the actor's scope, so an unreadable (or
  # absent) record leaves `record: nil` and the page shows the 404 panel. The
  # control is never drawn there, but the event can still be pushed by hand —
  # refuse it instead of running the action against nil.
  defp do_action(_id, _action, %{assigns: %{record: nil}} = socket, _options) do
    socket |> put_flash(:error, AshQuick.LiveView.ActionErrors.forbidden_message())
  end

  defp do_action(_id, action, socket, options) do
    record = socket.assigns.record

    case run_action(record, action, socket) do
      {:error, error} ->
        socket |> put_flash(:error, AshQuick.LiveView.ActionErrors.user_facing_message(error))

      _ ->
        socket
        |> assign(record: load_record!(socket, socket.assigns.params, options))
        |> Liveness.resync(:record, options)
    end
  end

  defp run_action(record, %Actions.Update{} = action, socket) do
    record
    |> Ash.update(
      action: action,
      scope: socket.assigns.scope,
      context: %{action_source: :ash_quick_details}
    )
  end

  defp run_action(record, %Actions.Destroy{} = action, socket) do
    record
    |> Ash.destroy(
      action: action,
      scope: socket.assigns.scope,
      context: %{action_source: :ash_quick_details}
    )
  end
end
