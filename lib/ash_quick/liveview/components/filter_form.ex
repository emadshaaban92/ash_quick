defmodule AshQuick.LiveView.Components.FilterForm do
  @moduledoc false
  use Phoenix.LiveComponent
  use Gettext, backend: AshQuick.Gettext
  import AshQuick.Components

  alias AshQuick.LiveView.CustomFilter
  alias AshQuick.LiveView.EnumOptions
  alias AshQuick.LiveView.FilterDatetime
  alias AshQuick.LiveView.Utils

  @datetime_types [Ash.Type.DateTime, Ash.Type.UtcDatetimeUsec, Ash.Type.UtcDatetime]

  @supported_types [
    Ash.Type.UUID,
    Ash.Type.UUIDv7,
    Ash.Type.Atom,
    Ash.Type.Boolean,
    Ash.Type.String,
    Ash.Type.CiString,
    Ash.Type.Date,
    Ash.Type.Integer,
    Ash.Type.Decimal,
    Ash.Type.DateTime,
    Ash.Type.UtcDatetimeUsec,
    Ash.Type.UtcDatetime,
    Ash.Type.Float
  ]

  attr :resource, :atom, required: true
  attr :action, :map, default: nil, doc: "the read the list runs"
  attr :scope, :map, required: true
  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex w-full">
      <.form
        id="custom-filter-form"
        for={%{}}
        phx-target={@myself}
        phx-change="update_filter"
        phx-submit="apply_filter"
        class="flex flex-col w-full"
      >
        <.render_custom_filter root={true} myself={@myself} group={@custom_filter} fields={@fields} />

        <div class="flex w-full gap-2 pt-4 pb-1">
          <button type="submit" class="btn btn-primary flex-1">{gettext("Apply Filters")}</button>
          <button
            type="button"
            phx-click="reset"
            phx-target={@myself}
            class="btn btn-ghost"
          >
            {gettext("Reset")}
          </button>
        </div>
      </.form>
    </div>
    """
  end

  defp render_custom_filter(assigns) do
    ~H"""
    <div class="space-y-1">
      <div class="flex items-center space-x-1">
        <select
          name={"operator-#{@group.uuid}"}
          class="select select-sm sm:w-auto"
        >
          {Phoenix.HTML.Form.options_for_select(
            [{gettext("AND"), "and"}, {gettext("OR"), "or"}],
            @group.operator
          )}
        </select>
        <button
          :if={not @root}
          type="button"
          phx-click="remove_filter"
          phx-target={@myself}
          phx-value-uuid={@group.uuid}
          class="btn btn-error btn-sm btn-square"
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </div>

      <div class="ms-2 border-s-2 border-base-300 ps-4 space-y-1">
        <%= for {filter, _filter_index} <- Enum.with_index(@group.children) do %>
          <%= if is_list(filter.children) do %>
            <.render_custom_filter root={false} myself={@myself} group={filter} fields={@fields} />
          <% else %>
            <div class="flex flex-col sm:flex-row sm:items-center gap-1">
              <select
                name={"field_name-#{filter.uuid}"}
                class="select select-sm sm:w-auto"
              >
                {Phoenix.HTML.Form.options_for_select(
                  field_options(@fields, filter.field_name),
                  filter.field_name
                )}
              </select>
              <div class="flex items-center gap-1">
                <select
                  name={"operator-#{filter.uuid}"}
                  class="select select-sm sm:w-auto shrink-0"
                >
                  {Phoenix.HTML.Form.options_for_select(
                    field_operators(
                      @fields
                      |> Enum.find(&(to_string(&1.name) == filter.field_name))
                    ),
                    filter.operator
                  )}
                </select>
                <.filter_value
                  filter={filter}
                  field={Enum.find(@fields, &(to_string(&1.name) == filter.field_name))}
                />

                <button
                  phx-click="remove_filter"
                  type="button"
                  phx-target={@myself}
                  phx-value-uuid={filter.uuid}
                  class="btn btn-error btn-sm btn-square"
                >
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </div>
            </div>
          <% end %>
        <% end %>

        <div :if={@fields != []} class="flex flex-wrap gap-1">
          <button
            phx-click="add_filter"
            type="button"
            phx-target={@myself}
            phx-value-uuid={@group.uuid}
            phx-value-nested="false"
            class="btn btn-success btn-sm"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> {pgettext("query builder", "Filter")}
          </button>
          <button
            phx-click="add_filter"
            type="button"
            phx-target={@myself}
            phx-value-uuid={@group.uuid}
            phx-value-nested="true"
            class="btn btn-success btn-sm"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Group")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Whether the field is picked from a fixed set decides the input, and no
  # guard can ask that, so it is asked once here.
  defp filter_value(%{field: field} = assigns) when not is_map_key(assigns, :choice) do
    assigns |> assign(:choice, EnumOptions.kind(field)) |> filter_value()
  end

  defp filter_value(%{field: %{type: t}} = assigns)
       when t in @datetime_types do
    ~H"""
    <input
      type="datetime-local"
      name={"value-#{@filter.uuid}"}
      value={FilterDatetime.to_local(@filter.value, AshQuick.Config.timezone())}
      class="input input-sm min-w-0 flex-1"
    />
    """
  end

  defp filter_value(%{field: %{type: t}} = assigns)
       when t in [Ash.Type.Date] do
    ~H"""
    <input
      type="date"
      name={"value-#{@filter.uuid}"}
      value={@filter.value}
      class="input input-sm min-w-0 flex-1"
    />
    """
  end

  defp filter_value(%{field: %{type: Ash.Type.Boolean}} = assigns) do
    ~H"""
    <select
      name={"value-#{@filter.uuid}"}
      class="select  select-sm min-w-0 flex-1"
    >
      {Phoenix.HTML.Form.options_for_select(
        [{"", nil}, {gettext("True"), true}, {gettext("False"), false}],
        @filter.value
      )}
    </select>
    """
  end

  # A value picked from a fixed set: an `Ash.Type.Enum`, or an atom with
  # `one_of`. A plain atom is typed in, below.
  defp filter_value(%{choice: :single} = assigns) do
    assigns = assign(assigns, :options, [{"", nil} | EnumOptions.options(assigns.field)])

    ~H"""
    <select
      name={"value-#{@filter.uuid}"}
      class="select  select-sm min-w-0 flex-1"
    >
      {Phoenix.HTML.Form.options_for_select(@options, @filter.value)}
    </select>
    """
  end

  # Any other field, and a row naming one this form does not offer: a URL
  # written for an actor who could see it, or by hand.
  defp filter_value(assigns) do
    ~H"""
    <input
      type="text"
      name={"value-#{@filter.uuid}"}
      value={@filter.value}
      class="input input-sm min-w-0 flex-1"
    />
    """
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_fields()
      |> maybe_assign_new_filter()

    {:ok, socket}
  end

  defp maybe_assign_new_filter(%{assigns: %{custom_filter: nil}} = socket) do
    socket
    |> assign(
      :custom_filter,
      %CustomFilter{
        operator: "and",
        uuid: Ash.UUID.generate(),
        children:
          case first_leaf(socket.assigns.fields) do
            nil -> []
            leaf -> [CustomFilter.new_leaf(leaf)]
          end
      }
    )
  end

  defp maybe_assign_new_filter(socket), do: socket

  @impl true
  def handle_event("add_filter", %{"uuid" => uuid, "nested" => nested}, socket) do
    # No field to start a row on: the buttons are not rendered then, so this is
    # a stale page or a forged event.
    case first_leaf(socket.assigns.fields) do
      nil ->
        {:noreply, socket}

      leaf ->
        custom_filter = CustomFilter.add_filter(socket.assigns.custom_filter, uuid, nested, leaf)
        {:noreply, assign(socket, :custom_filter, custom_filter)}
    end
  end

  def handle_event("remove_filter", %{"uuid" => uuid}, socket) do
    custom_filter =
      CustomFilter.remove_filter(
        socket.assigns.custom_filter,
        uuid
      )

    {:noreply, assign(socket, :custom_filter, custom_filter)}
  end

  def handle_event(
        "update_filter",
        %{"_target" => ["operator-" <> uuid]} = params,
        socket
      ) do
    custom_filter =
      CustomFilter.update_filter(
        socket.assigns.custom_filter,
        uuid,
        :operator,
        params["operator-" <> uuid]
      )

    {:noreply, assign(socket, :custom_filter, custom_filter)}
  end

  def handle_event(
        "update_filter",
        %{"_target" => ["field_name-" <> uuid]} = params,
        socket
      ) do
    field_name = params["field_name-" <> uuid]

    # A field this form does not offer is ignored: a stale page, or an event
    # naming a field the actor may not see.
    case Enum.find(socket.assigns.fields, &(to_string(&1.name) == field_name)) do
      nil ->
        {:noreply, socket}

      field ->
        custom_filter =
          socket.assigns.custom_filter
          |> CustomFilter.update_filter(uuid, :field_name, field_name)
          |> CustomFilter.update_filter(
            uuid,
            :operator,
            field |> field_operators() |> first_operator()
          )
          |> CustomFilter.update_filter(uuid, :value, "")

        {:noreply, assign(socket, :custom_filter, custom_filter)}
    end
  end

  def handle_event(
        "update_filter",
        %{"_target" => ["value-" <> uuid]} = params,
        socket
      ) do
    value = held_value(socket, uuid, params["value-" <> uuid])

    custom_filter =
      CustomFilter.update_filter(
        socket.assigns.custom_filter,
        uuid,
        :value,
        value
      )

    {:noreply, assign(socket, :custom_filter, custom_filter)}
  end

  def handle_event("apply_filter", _, socket) do
    notify_parent(socket.assigns.custom_filter)
    {:noreply, socket}
  end

  def handle_event("reset", _, socket) do
    notify_parent(nil)
    {:noreply, socket}
  end

  # A timestamp is typed in the zone the list shows it in, and held as the UTC
  # instant that means. See `AshQuick.LiveView.FilterDatetime`.
  defp held_value(socket, uuid, value) do
    with %CustomFilter{field_name: name} <- CustomFilter.find(socket.assigns.custom_filter, uuid),
         %{type: type} when type in @datetime_types <-
           Enum.find(socket.assigns.fields, &(to_string(&1.name) == name)) do
      FilterDatetime.to_utc(value, AshQuick.Config.timezone())
    else
      _ -> value
    end
  end

  # Asked only when what it depends on changed, rather than on every render,
  # event or re-render of the modal: a field policy is a check against the
  # actor, and the answer does not change while the form is open.
  defp assign_fields(socket) do
    if Enum.any?([:resource, :action, :scope], &changed?(socket, &1)) do
      %{resource: resource, action: action, scope: scope} = socket.assigns
      assign(socket, :fields, fields(resource, action, scope))
    else
      socket
    end
  end

  # A row can name a field this form does not offer: a link written for an
  # actor who could see it, or by hand. The select holds it as a disabled
  # option, so it shows the field the row filters on instead of the first one
  # offered, which a browser would show and could not then be picked.
  defp field_options(fields, field_name) do
    options = Enum.map(fields, &{Utils.humanize(&1.name), to_string(&1.name)})

    if is_binary(field_name) and not Enum.any?(options, &(elem(&1, 1) == field_name)),
      do: [[key: Utils.humanize(field_name), value: field_name, disabled: true] | options],
      else: options
  end

  # A new row starts on the first field offered: no one field is one every
  # resource has, or one every actor may see.
  defp first_leaf([field | _]),
    do: %{
      field_name: to_string(field.name),
      operator: field |> field_operators() |> first_operator()
    }

  defp first_leaf([]), do: nil

  defp first_operator([{_label, operator} | _]), do: operator
  defp first_operator([]), do: nil

  # A field a field policy hides from the actor on every row is not offered:
  # Ash would read it as `nil` in the filter, so the list would come back empty
  # and look like an answer. One hidden on some rows only stays.
  # Without the list's read, the field policies are asked against the
  # resource's primary read, so a caller that names none still hides them.
  defp fields(resource, nil, scope) do
    case Ash.Resource.Info.primary_action(resource, :read) do
      nil -> fields(resource)
      action -> fields(resource, action, scope)
    end
  end

  defp fields(resource, action, scope) do
    offered = fields(resource)
    visible = offered |> Enum.map(& &1.name) |> Utils.visible_fields(resource, action, scope)

    Enum.filter(offered, &(&1.name in visible))
  end

  defp fields(resource) do
    belongs_to_source_attributes =
      resource
      |> Ash.Resource.Info.relationships()
      |> Enum.filter(&(&1.type == :belongs_to))
      |> Enum.map(& &1.source_attribute)

    resource
    |> Ash.Resource.Info.fields([:attributes, :aggregates, :calculations])
    |> Enum.reject(&(&1.name in belongs_to_source_attributes))
    |> Enum.filter(&(&1.filterable? and &1.public? and supported?(&1)))
  end

  # A field with a fixed set of values is offered whatever its type: an
  # `Ash.Type.Enum` is a module of its own, so no list of types could name it.
  # An atom without `one_of` is offered too, and typed in.
  defp supported?(field), do: EnumOptions.kind(field) == :single or field.type in @supported_types

  @equality [{"=", "equals"}, {"!=", "not_equals"}]

  # A field with a fixed set of values compares by value, whatever its type;
  # anything else by what its type allows.
  defp field_operators(field) do
    if EnumOptions.kind(field) == :single, do: @equality, else: type_operators(field)
  end

  defp type_operators(%{type: t})
       when t in [Ash.Type.UUID, Ash.Type.UUIDv7, Ash.Type.Atom, Ash.Type.Boolean],
       do: @equality

  defp type_operators(%{type: t}) when t in [Ash.Type.String, Ash.Type.CiString] do
    [
      {"=", "equals"},
      {"!=", "not_equals"},
      {gettext("Contains"), "contains"},
      {gettext("Starts With"), "starts_with"}
    ]
  end

  defp type_operators(%{type: t})
       when t in [Ash.Type.Date, Ash.Type.Integer, Ash.Type.Decimal] do
    [
      {"=", "equals"},
      {"!=", "not_equals"},
      {">", "gt"},
      {">=", "gte"},
      {"<", "lt"},
      {"<=", "lte"}
    ]
  end

  defp type_operators(%{type: t})
       when t in @datetime_types or t == Ash.Type.Float do
    [
      {">", "gt"},
      {">=", "gte"},
      {"<", "lt"},
      {"<=", "lte"}
    ]
  end

  defp type_operators(_field), do: []

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
