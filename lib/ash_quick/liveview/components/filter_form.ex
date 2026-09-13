defmodule AshQuick.LiveView.Components.FilterForm do
  @moduledoc false
  use Phoenix.LiveComponent
  use Gettext, backend: AshQuick.Gettext
  import AshQuick.Components

  alias AshQuick.LiveView.CustomFilter
  alias AshQuick.LiveView.Utils

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
  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:fields, fields(assigns.resource))

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
                  @fields |> Enum.map(&{Utils.humanize(&1.name), &1.name}),
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

        <div class="flex flex-wrap gap-1">
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

  defp filter_value(%{field: %{type: t}} = assigns)
       when t in [Ash.Type.DateTime, Ash.Type.UtcDatetimeUsec, Ash.Type.UtcDatetime] do
    ~H"""
    <input
      type="datetime-local"
      name={"value-#{@filter.uuid}"}
      value={@filter.value}
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
        [{"", nil}, {"True", true}, {"False", false}],
        @filter.value
      )}
    </select>
    """
  end

  defp filter_value(%{field: %{type: Ash.Type.Atom, constraints: constraints}} = assigns)
       when constraints != [] do
    atom_options =
      (constraints[:one_of] || [])
      |> Enum.map(&{&1 |> Utils.humanize(), &1})

    assigns =
      assigns
      |> assign(:atom_options, [{"", nil} | atom_options])

    ~H"""
    <select
      name={"value-#{@filter.uuid}"}
      class="select  select-sm min-w-0 flex-1"
    >
      {Phoenix.HTML.Form.options_for_select(@atom_options, @filter.value)}
    </select>
    """
  end

  defp filter_value(%{field: %{}} = assigns) do
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
        children: [
          %CustomFilter{
            uuid: Ash.UUID.generate(),
            field_name: "id",
            operator: "equals",
            value: ""
          }
        ]
      }
    )
  end

  defp maybe_assign_new_filter(socket), do: socket

  @impl true
  def handle_event("add_filter", %{"uuid" => uuid, "nested" => nested}, socket) do
    custom_filter =
      CustomFilter.add_filter(
        socket.assigns.custom_filter,
        uuid,
        nested
      )

    {:noreply, assign(socket, :custom_filter, custom_filter)}
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
    fields = fields(socket.assigns.resource)

    allowed_operators =
      fields |> Enum.find(&(to_string(&1.name) == field_name)) |> field_operators()

    custom_filter =
      socket.assigns.custom_filter
      |> CustomFilter.update_filter(
        uuid,
        :field_name,
        field_name
      )
      |> CustomFilter.update_filter(
        uuid,
        :operator,
        List.first(allowed_operators) |> elem(1)
      )
      |> CustomFilter.update_filter(
        uuid,
        :value,
        ""
      )

    {:noreply, assign(socket, :custom_filter, custom_filter)}
  end

  def handle_event(
        "update_filter",
        %{"_target" => ["value-" <> uuid]} = params,
        socket
      ) do
    custom_filter =
      CustomFilter.update_filter(
        socket.assigns.custom_filter,
        uuid,
        :value,
        params["value-" <> uuid]
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

  defp fields(resource) do
    belongs_to_source_attributes =
      resource
      |> Ash.Resource.Info.relationships()
      |> Enum.filter(&(&1.type == :belongs_to))
      |> Enum.map(& &1.source_attribute)

    resource
    |> Ash.Resource.Info.fields([:attributes, :aggregates, :calculations])
    |> Enum.reject(&(&1.name in belongs_to_source_attributes))
    |> Enum.filter(&(&1.filterable? and &1.public? and &1.type in @supported_types))
  end

  defp field_operators(%{type: t})
       when t in [Ash.Type.UUID, Ash.Type.UUIDv7, Ash.Type.Atom, Ash.Type.Boolean] do
    [
      {"=", "equals"},
      {"!=", "not_equals"}
    ]
  end

  defp field_operators(%{type: t}) when t in [Ash.Type.String, Ash.Type.CiString] do
    [
      {"=", "equals"},
      {"!=", "not_equals"},
      {gettext("Contains"), "contains"},
      {gettext("Starts With"), "starts_with"}
    ]
  end

  defp field_operators(%{type: t})
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

  defp field_operators(%{type: t})
       when t in [
              Ash.Type.DateTime,
              Ash.Type.UtcDatetimeUsec,
              Ash.Type.UtcDatetime,
              Ash.Type.Float
            ] do
    [
      {">", "gt"},
      {">=", "gte"},
      {"<", "lt"},
      {"<=", "lte"}
    ]
  end

  defp field_operators(_field), do: []

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
