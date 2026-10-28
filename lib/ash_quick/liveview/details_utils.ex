defmodule AshQuick.LiveView.DetailsUtils do
  @moduledoc false
  require Ash.Query
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 2]

  alias Ash.Resource.Actions
  alias AshQuick.LiveView.ActionErrors
  alias AshQuick.LiveView.QuickField
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
    |> then(&Ash.Query.load(&1, actor_load(options.resource, &1.tenant), strict?: true))
    |> then(
      &Ash.Query.load(&1, related_hint_load(options.resource, options.details_fields, &1.tenant))
    )
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
  # with it — nested down to the actor's label and hint, because this load is
  # strict and an unlisted field on the actor would come back `NotLoaded`.
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
  def actor_load(resource, tenant \\ nil) do
    case AshQuick.Config.actor_resource() do
      nil ->
        []

      actor ->
        fields =
          Enum.reject([AshQuick.Info.display_label(actor)], &is_nil/1) ++
            Utils.hint_fields(actor, tenant)

        resource |> AshQuick.Info.actor_fields() |> Enum.map(&{&1, fields})
    end
  end

  @doc false
  # The display hint of each record a details field names — see
  # `QuickField.names_record?/2` — since the page links that record and the
  # hint is the link's tooltip. Merged into the field's own load rather than
  # strict, so it adds the hint without narrowing what the field selected.
  def related_hint_load(resource, fields, tenant \\ nil) do
    for {chain, destination} <- linked_records(resource, fields),
        hint <- Utils.hint_fields(destination, tenant),
        uniq: true,
        do: chain |> List.foldr([hint], &[{&1, &2}]) |> hd()
  end

  @doc false
  # Every record the details `fields` name, as the relationships reaching it
  # and its resource.
  def linked_records(resource, fields) do
    fields
    |> Enum.flat_map(&QuickField.named_records(resource, &1.path))
    |> Enum.uniq()
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
    case options.resource |> Utils.record_actions() |> Utils.offered_action(action_name) do
      nil -> {:halt, put_flash(socket, :error, ActionErrors.forbidden_message())}
      action -> {:halt, row_action(id, action, socket, options)}
    end
  end

  defp handle_details_events(_, _, socket, _options), do: {:cont, socket}

  # Every action opens at its own URL, over this page, and runs from there: a
  # form for one that takes input, a confirmation for one that does not. What
  # may open and run it is the modal's to decide, as it is for a typed URL.
  #
  # `load_record!/3` reads through the actor's scope, so an unreadable (or
  # absent) record leaves `record: nil` and the page shows the 404 panel. The
  # control is never drawn there, but the event can still be pushed by hand —
  # refuse it rather than open an action on a record nobody here can see.
  defp row_action(id, action, %{assigns: %{record: %{id: id}}} = socket, _options) do
    params = socket.assigns.params |> URLParams.to_action_params(action.name, id: id)
    push_patch(socket, to: URLParams.full_path(socket.assigns.base_path, params))
  end

  defp row_action(_id, _action, socket, _options) do
    put_flash(socket, :error, ActionErrors.forbidden_message())
  end
end
