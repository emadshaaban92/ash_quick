defmodule AshQuick.LiveView.Components.BelongsToInput do
  @moduledoc false
  use Phoenix.LiveComponent
  import AshQuick.Components
  import AshQuick.LiveView.Components.RecordOption
  require Ash.Query

  alias AshQuick.LiveView.Utils

  @impl true
  def render(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns =
      assigns
      |> assign(:errors, AshQuick.LiveView.FieldErrors.for_select(field))
      |> assign(:placeholder, assigns[:placeholder] || "")

    ~H"""
    <div phx-feedback-for={@field.name} class="sm:col-span-2 phx-submit-loading:pointer-events-none">
      <.label :if={@label} for={@field.id}>{@label}</.label>
      <span :if={@required} class="text-error"> &ast;</span>
      <LiveSelect.live_select
        field={@field}
        style={:daisyui}
        container_extra_class="w-full"
        update_min_len={0}
        allow_clear={true}
        options={@default_options}
        value_mapper={@value_mapper}
        placeholder={@placeholder}
        phx-target={@myself}
        phx-focus="set-default"
      >
        <:option :let={option}><.record_option option={option} /></:option>
      </LiveSelect.live_select>

      <AshQuick.LiveView.FieldErrors.used_marker field={@field} />
      <.error :for={msg <- @errors} class="-mt-6">{msg}</.error>
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns) |> set_default_options() |> set_field() |> set_value_option()}
  end

  # The parent re-renders this on every keystroke in the form, and LiveSelect
  # keeps the options it mounted with across a re-render anyway. So they are
  # read once per record the form edits, not once per keystroke — a read that
  # loads each option's hint, which may be an aggregate.
  defp set_default_options(%{assigns: %{form: form, options_for: data}} = socket)
       when form.data == data,
       do: socket

  defp set_default_options(socket) do
    assign(socket,
      default_options: get_options(socket),
      options_for: socket.assigns.form.data
    )
  end

  defp set_field(socket) do
    %{form: form, relationship: relationship} = socket.assigns
    assign(socket, field: form[relationship.source_attribute])
  end

  # LiveSelect labels the field's value from the options it holds, and it drops
  # them once a pick is made. The component drawn at a sub-form's position can
  # be handed another row's value — a ✕ above it moves every later row up — so
  # the value's option is kept here, and LiveSelect is handed it whatever it
  # still holds. It is read only when the value is one no option here names,
  # and once per value: a record the reader may not see stays unlabelled.
  defp set_value_option(socket) do
    value = socket.assigns.field.value

    option =
      case socket.assigns do
        _blank when value in [nil, ""] ->
          nil

        %{value_option: {^value, option}} ->
          option

        %{default_options: options} ->
          Enum.find(options, &(&1.value == value)) || read_option(socket, value)
      end

    assign(socket,
      value_option: {value, option},
      value_mapper: &if(option && &1 == value, do: option, else: &1)
    )
  end

  defp read_option(socket, value) do
    %{relationship: relationship} = socket.assigns
    key = relationship.destination_attribute

    relationship
    |> option_query(nil, socket.assigns.scope)
    |> Ash.Query.filter(^[{key, value}])
    |> Ash.read_one()
    |> case do
      {:ok, %{} = record} -> Utils.to_option(record, key)
      _not_readable -> nil
    end
  end

  @impl true
  def handle_event(
        "live_select_change",
        %{"text" => search, "id" => live_select_id},
        socket
      ) do
    send_update(LiveSelect.Component,
      id: live_select_id,
      options: get_options(socket, search)
    )

    {:noreply, socket}
  end

  @impl true
  def handle_event("set-default", %{"id" => live_select_id}, socket) do
    send_update(LiveSelect.Component,
      id: live_select_id,
      options: get_options(socket)
    )

    {:noreply, socket}
  end

  # An option is worth exactly the field the foreign key points at, since that
  # is what the form writes back into `source_attribute`. Named rather than
  # assumed to be `:id`: `destination_attribute` is free to name another field,
  # and a primary key need not be called `:id` at all.
  defp get_options(socket, search \\ nil) do
    %{form: form, relationship: relationship} = socket.assigns
    key = relationship.destination_attribute

    default_options =
      relationship
      |> option_query(search, socket.assigns.scope)
      |> maybe_add_relationship_filters(relationship.filters)
      |> Utils.filter_inactive()
      |> Ash.Query.page(count: false)
      |> Ash.read!()

    default_options_with_current =
      case Ash.Resource.loaded?(form.data, relationship.name) do
        true ->
          [Map.fetch!(form.data, relationship.name) | default_options.results]
          |> List.flatten()
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq_by(&Map.fetch!(&1, key))

        false ->
          default_options.results
      end

    Enum.map(default_options_with_current, &Utils.to_option(&1, key))
  end

  # The records the dropdown offers, each with what its option shows.
  defp option_query(relationship, search, scope) do
    relationship.destination
    |> Ash.Query.for_read(
      Utils.lookup_action!(relationship),
      Utils.lookup_input(relationship.destination, search),
      scope: scope
    )
    |> Ash.Query.select(relationship.destination_attribute)
    |> Utils.load_display_label()
    |> Utils.load_display_hint()
  end

  defp maybe_add_relationship_filters(query, []), do: query

  defp maybe_add_relationship_filters(query, [%Ash.Resource.Dsl.Filter{filter: filter} | rest]) do
    query |> Ash.Query.filter(^filter) |> maybe_add_relationship_filters(rest)
  end
end
