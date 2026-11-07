defmodule AshQuick.LiveView.Components.FilterForm do
  @moduledoc false
  use Phoenix.LiveComponent
  use Gettext, backend: AshQuick.Gettext
  import AshQuick.Components

  alias AshQuick.Labels
  alias AshQuick.LiveView.ActionErrors
  alias AshQuick.LiveView.CustomFilter
  alias AshQuick.LiveView.EnumOptions
  alias AshQuick.LiveView.FilterField
  alias AshQuick.LiveView.LocalDatetime

  @datetime_types [Ash.Type.DateTime, Ash.Type.UtcDatetimeUsec, Ash.Type.UtcDatetime]

  attr :resource, :atom, required: true
  attr :action, :map, default: nil, doc: "the read the list runs"

  attr :filterable, :list,
    default: nil,
    doc:
      "the fields offered, in order, as `filterable:` names them; `nil` for every field of " <>
        "the resource's own a filter can take"

  attr :scope, :map, required: true
  attr :close, :any, default: nil, doc: "a path or a `JS` command Cancel runs to close the modal"

  attr :labels, :map,
    default: %{},
    doc: "the list's column labels by field name, which name a field here as its column does"

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
        <.render_custom_filter
          root={true}
          myself={@myself}
          group={@custom_filter}
          resource={@resource}
          fields={@fields}
          emptiable={@emptiable}
          labels={@labels}
          value_errors={@value_errors}
          timezone={@timezone}
        />

        <div class="flex w-full gap-2 pt-4 pb-1">
          <button type="submit" class="btn btn-primary flex-1">{gettext("Apply Filters")}</button>
          <AshQuick.LiveView.Components.FormView.cancel_link close={@close} />
          <button
            type="button"
            phx-click="reset"
            phx-target={@myself}
            class="btn btn-ghost text-error"
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
          <%= if CustomFilter.group?(filter) do %>
            <.render_custom_filter
              root={false}
              myself={@myself}
              group={filter}
              resource={@resource}
              fields={@fields}
              emptiable={@emptiable}
              labels={@labels}
              value_errors={@value_errors}
              timezone={@timezone}
            />
          <% else %>
            <.filter_row
              filter={filter}
              resource={@resource}
              fields={@fields}
              emptiable={@emptiable}
              labels={@labels}
              field={field_for(@fields, filter.field_name)}
              error={@value_errors[filter.uuid]}
              timezone={@timezone}
              myself={@myself}
            />
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

  # One row: its field, operator and value, and the error under it when its
  # value was refused. `field` is the offered `FilterField` it names, or `nil`.
  # Its value is drawn by the field it reaches, and labelled by the resource
  # holding it, which a field through a relationship is not the list's.
  defp filter_row(assigns) do
    ~H"""
    <div class="flex flex-col sm:flex-row sm:items-center gap-1">
      <select
        name={"field_name-#{@filter.uuid}"}
        class="select select-sm sm:w-auto"
      >
        {Phoenix.HTML.Form.options_for_select(
          field_options(@fields, @filter.field_name, @labels, @resource),
          @filter.field_name
        )}
      </select>
      <div class="flex items-center gap-1">
        <select
          name={"operator-#{@filter.uuid}"}
          class="select select-sm w-auto shrink-0"
        >
          {Phoenix.HTML.Form.options_for_select(
            operator_options(@field, @filter.operator, @emptiable),
            @filter.operator
          )}
        </select>
        <.filter_value
          filter={@filter}
          field={@field && @field.field}
          resource={(@field && @field.resource) || @resource}
          error={@error}
          timezone={@timezone}
          myself={@myself}
        />

        <button
          phx-click="remove_filter"
          type="button"
          phx-target={@myself}
          phx-value-uuid={@filter.uuid}
          class="btn btn-error btn-sm btn-square"
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </div>
    </div>
    <div :if={@error} id={"value-error-#{@filter.uuid}"}>
      <.error class="mt-0">{@error}</.error>
    </div>
    """
  end

  # Whether the field is picked from a fixed set decides the input, and no
  # guard can ask that, so it is asked once here.
  defp filter_value(%{field: field} = assigns) when not is_map_key(assigns, :choice) do
    assigns |> assign(:choice, EnumOptions.kind(field)) |> filter_value()
  end

  # Is Empty and Is Not Empty compare with nothing. The space keeps the row's
  # ✕ where the other rows have theirs.
  defp filter_value(%{filter: %{operator: operator}} = assigns)
       when operator in ~w(is_nil is_not_nil) do
    ~H"""
    <span class="flex-1"></span>
    """
  end

  # Any Of picks several values from a fixed set, and so does Has Any Of from
  # the set a list's items are picked from: as tags, searched by label.
  #
  # LiveSelect makes an atom of its field's name, so the field is a fixed
  # `values` and the row's uuid goes in the form's name: its picks post as
  # `value-<uuid>[values][]`. Its id names the field too, so a row moved to
  # another field gets a fresh selection and that field's options. A field
  # draws this under one operator only, so the operator is left out of it.
  defp filter_value(%{filter: %{operator: operator}, choice: choice} = assigns)
       when (operator == "in" and choice == :single) or
              (operator == "has_any" and choice == :array) do
    %{filter: filter, field: field, resource: resource} = assigns
    held = held_values(filter.value)
    {options, labels} = value_choices(field, resource, held)

    assigns =
      assign(assigns,
        picker_id: picker_id(filter),
        picker_field: to_form(%{"values" => held}, as: "value-#{filter.uuid}")[:values],
        options: options,
        value_mapper: &%{label: Map.fetch!(labels, &1), value: &1}
      )

    ~H"""
    <div
      id={"#{@picker_id}-wrap"}
      phx-hook=".ValuesPicker"
      data-error-id={@error && "value-error-#{@filter.uuid}"}
      class="min-w-0 flex-1"
    >
      <%!-- An input holding picks is drawn as primary, which would hide the
      error's colour, so the error takes its place then. The tag class is
      ChoiceInput's: daisyUI 5's badge is a fixed-height
      box with inline padding only, so live_select's preset adds vertical
      padding the line has no room for and the text spills out. A long set
      scrolls within the dropdown, as the native select's five rows did;
      daisyUI's menu would wrap it into columns, so it is kept to one. --%>
      <LiveSelect.live_select
        id={@picker_id}
        field={@picker_field}
        style={:daisyui}
        mode={:quick_tags}
        container_extra_class="w-full"
        text_input_extra_class={if @error, do: "input-sm input-error", else: "input-sm"}
        text_input_selected_class={if @error, do: "input-error"}
        dropdown_extra_class="max-h-60 overflow-y-auto flex-nowrap"
        tag_class="badge badge-primary h-auto min-h-6 py-0.5 max-w-full whitespace-normal"
        update_min_len={0}
        options={@options}
        value_mapper={@value_mapper}
        phx-target={@myself}
        phx-focus="offer_values"
      />
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ValuesPicker">
      // Puts the aria wiring other rows render on their input on LiveSelect's,
      // which takes no attributes for it. Set through `js()`, so it outlives
      // LiveView's patches of the input, which never renders it itself.
      //
      // Brings an opened dropdown into view: the modal scrolls its content,
      // so one opened near its bottom edge would be cut off below it.
      // LiveSelect draws its dropdown as a new list each time it opens.
      export default {
        mounted() {
          this.mark()
          this.observer = new MutationObserver(() => this.reveal())
          this.observer.observe(this.el, {childList: true, subtree: true})
        },
        updated() { this.mark() },
        destroyed() { this.observer.disconnect() },
        mark() {
          const input = this.el.querySelector("input[type=text]")
          if (!input) return
          const errorId = this.el.dataset.errorId
          if (errorId) {
            this.js().setAttribute(input, "aria-invalid", "true")
            this.js().setAttribute(input, "aria-describedby", errorId)
          } else {
            this.js().removeAttribute(input, "aria-invalid")
            this.js().removeAttribute(input, "aria-describedby")
          }
        },
        reveal() {
          const list = this.el.querySelector("ul")
          if (list && list !== this.shown) list.scrollIntoView({block: "nearest"})
          this.shown = list
        }
      }
    </script>
    """
  end

  # Any Of or Has Any Of on a field without a fixed set, which only a link
  # carries: its values typed in, one after another, split again at each
  # comma.
  defp filter_value(%{filter: %{operator: operator}} = assigns)
       when operator in ~w(in has_any) do
    ~H"""
    <input
      type="text"
      name={"value-#{@filter.uuid}"}
      value={typed_list(@filter.value, @field, @timezone)}
      class={["input input-sm min-w-0 flex-1", @error && "input-error"]}
      {invalid_attrs(@filter, @error)}
    />
    """
  end

  # On Day names a whole day of a timestamp, in the zone the list shows it in.
  defp filter_value(%{filter: %{operator: "on"}} = assigns), do: date_input(assigns)

  defp filter_value(%{field: %{type: t}} = assigns)
       when t in @datetime_types do
    ~H"""
    <input
      type="datetime-local"
      name={"value-#{@filter.uuid}"}
      value={LocalDatetime.to_local(@filter.value, @timezone)}
      step="1"
      class={["input input-sm min-w-0 flex-1", @error && "input-error"]}
      {invalid_attrs(@filter, @error)}
    />
    """
  end

  defp filter_value(%{field: %{type: Ash.Type.Date}} = assigns), do: date_input(assigns)

  defp filter_value(%{field: %{type: Ash.Type.Boolean}} = assigns) do
    ~H"""
    <select
      name={"value-#{@filter.uuid}"}
      class={["select select-sm min-w-0 flex-1", @error && "select-error"]}
      {invalid_attrs(@filter, @error)}
    >
      {Phoenix.HTML.Form.options_for_select(
        [{"", nil}, {gettext("Yes"), true}, {gettext("No"), false}],
        @filter.value
      )}
    </select>
    """
  end

  # A value picked from a fixed set: an `Ash.Type.Enum`, or an atom with
  # `one_of`. A plain atom is typed in, below.
  defp filter_value(%{choice: :single} = assigns) do
    assigns =
      assign(assigns, :options, [{"", nil} | EnumOptions.options(assigns.field, assigns.resource)])

    ~H"""
    <select
      name={"value-#{@filter.uuid}"}
      class={["select select-sm min-w-0 flex-1", @error && "select-error"]}
      {invalid_attrs(@filter, @error)}
    >
      {Phoenix.HTML.Form.options_for_select(@options, @filter.value)}
    </select>
    """
  end

  # Any other field, and a row naming one this form does not offer: a URL
  # written for an actor who could see it, or by hand. A link can hand it a
  # list, which reads as Any Of's typed values do.
  defp filter_value(assigns) do
    ~H"""
    <input
      type="text"
      name={"value-#{@filter.uuid}"}
      value={typed_list(@filter.value, @field, @timezone)}
      class={["input input-sm min-w-0 flex-1", @error && "input-error"]}
      {invalid_attrs(@filter, @error)}
    />
    """
  end

  defp date_input(assigns) do
    ~H"""
    <input
      type="date"
      name={"value-#{@filter.uuid}"}
      value={@filter.value}
      class={["input input-sm min-w-0 flex-1", @error && "input-error"]}
      {invalid_attrs(@filter, @error)}
    />
    """
  end

  # A value as a text input shows it: as a chip writes one, a list's values
  # joined by commas, and a timestamp in the zone the list shows it in.
  # `Phoenix.HTML` would read a list as iodata, which raises for most.
  defp typed_list(nil, _field, _timezone), do: nil

  defp typed_list(values, field, timezone) when is_list(values),
    do: values |> Enum.map(&typed_list(&1, field, timezone)) |> CustomFilter.as_written()

  defp typed_list(value, %{type: type}, timezone) when type in @datetime_types,
    do: LocalDatetime.to_local(value, timezone)

  defp typed_list(value, _field, _timezone), do: CustomFilter.as_written(value)

  # Ties a value's input to the error under its row, for a screen reader.
  defp invalid_attrs(_filter, nil), do: []

  defp invalid_attrs(filter, _error),
    do: ["aria-invalid": "true", "aria-describedby": "value-error-#{filter.uuid}"]

  # The LiveSelect a row picks its values with, by the row and its field. A
  # field through a relationship names its path with a dot, which a CSS
  # selector would read as a class, so the id joins it with dashes instead.
  defp picker_id(%CustomFilter{uuid: uuid, field_name: name}),
    do: "filter-values-#{uuid}-#{String.replace(to_string(name), ".", "--")}"

  # The values a row holds, as its tags: a link can hold one bare value, a
  # blank or an empty list, or the same value twice.
  defp held_values(value),
    do: value |> List.wrap() |> Enum.reject(&(&1 in [nil, "", []])) |> Enum.uniq()

  # The values `field` offers as `{label, value}` options, and the label of
  # each, by value, for those offered and those `held` beside them. A value is
  # the string a row holds and the URL carries, whatever its type: an atom
  # picked is held as the string it posts as. One held outside the set, which
  # only a link carries, is labelled too, so its tag can be seen and removed.
  #
  # LiveSelect tells a picked option from the others by its label, so values
  # sharing a label each name their value too, rather than unpicking each
  # other.
  defp value_choices(field, resource, held) do
    options =
      field
      |> EnumOptions.options(resource)
      |> Enum.map(fn {label, value} -> {label, to_string(value)} end)
      |> distinct_labels([])

    offered = Map.new(options, fn {label, value} -> {value, label} end)
    taken = options |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    labels =
      held
      |> Enum.reject(&Map.has_key?(offered, &1))
      |> Enum.map(&{held_label(field, &1, resource), &1})
      |> distinct_labels(taken)
      |> Map.new(fn {label, value} -> {value, label} end)
      |> Map.merge(offered)

    {options, labels}
  end

  # Labels shared within `pairs`, or with one already `taken`, name the value.
  defp distinct_labels(pairs, taken) do
    counts = Enum.frequencies_by(pairs, &elem(&1, 0))

    Enum.map(pairs, fn {label, value} ->
      if counts[label] > 1 or label in taken,
        do: {"#{label} (#{CustomFilter.as_written(value)})", value},
        else: {label, value}
    end)
  end

  defp held_label(field, value, resource) when is_binary(value) or is_atom(value),
    do: EnumOptions.label(field, value, resource)

  defp held_label(_field, value, _resource), do: CustomFilter.as_written(value)

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      # The zone the list shows timestamps in, which a timestamp is typed in.
      |> assign(:timezone, AshQuick.Scope.timezone(assigns[:scope] || socket.assigns[:scope]))
      |> assign_new(:value_errors, fn -> %{} end)
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
    # A group goes with its rows, and so do their errors.
    removed =
      case CustomFilter.find(socket.assigns.custom_filter, uuid) do
        nil -> [uuid]
        node -> [uuid | node |> CustomFilter.leaves() |> Enum.map(& &1.uuid)]
      end

    custom_filter =
      CustomFilter.remove_filter(
        socket.assigns.custom_filter,
        uuid
      )

    {:noreply, socket |> assign(:custom_filter, custom_filter) |> forget_errors(removed)}
  end

  # LiveSelect asks for the options a search matches, and on focus for all
  # of them again, since a search narrowed them. Re-rendered options are
  # ignored once it has mounted, so they are sent to it directly.
  def handle_event("live_select_change", %{"id" => id, "text" => text}, socket),
    do: {:noreply, offer_values(socket, id, text)}

  def handle_event("offer_values", %{"id" => id}, socket),
    do: {:noreply, offer_values(socket, id, nil)}

  def handle_event(
        "update_filter",
        %{"_target" => ["operator-" <> uuid]} = params,
        socket
      ) do
    operator = params["operator-" <> uuid]

    # A row's value follows it to an operator that takes the same kind of
    # value: one value in or out of Any Of's list, and none to Is Empty.
    custom_filter =
      case CustomFilter.find(socket.assigns.custom_filter, uuid) do
        # A row is a node without children, `children: []` included, as a
        # link can write one.
        %CustomFilter{children: children, operator: from, value: value}
        when children in [nil, []] ->
          socket.assigns.custom_filter
          |> CustomFilter.update_filter(uuid, :operator, operator)
          |> CustomFilter.update_filter(
            uuid,
            :value,
            CustomFilter.reshape_value(value, from, operator)
          )

        _ ->
          CustomFilter.update_filter(socket.assigns.custom_filter, uuid, :operator, operator)
      end

    {:noreply, socket |> assign(:custom_filter, custom_filter) |> forget_error(uuid)}
  end

  def handle_event(
        "update_filter",
        %{"_target" => ["field_name-" <> uuid]} = params,
        socket
      ) do
    field_name = params["field_name-" <> uuid]

    # A field this form does not offer is ignored: a stale page, or an event
    # naming a field the actor may not see.
    case field_for(socket.assigns.fields, field_name) do
      nil ->
        {:noreply, socket}

      %FilterField{field: field} ->
        custom_filter =
          socket.assigns.custom_filter
          |> CustomFilter.update_filter(uuid, :field_name, field_name)
          |> CustomFilter.update_filter(
            uuid,
            :operator,
            first_operator(field)
          )
          |> CustomFilter.update_filter(uuid, :value, "")

        {:noreply, socket |> assign(:custom_filter, custom_filter) |> forget_error(uuid)}
    end
  end

  def handle_event(
        "update_filter",
        %{"_target" => ["value-" <> uuid]} = params,
        socket
      ) do
    {:noreply, put_value(socket, uuid, params["value-" <> uuid])}
  end

  # A row's LiveSelect posts its picks as `value-<uuid>[values][]`, and once
  # the last is removed only its `[values_empty_selection]` marker, which
  # leaves the row holding none.
  def handle_event(
        "update_filter",
        %{"_target" => ["value-" <> uuid, _input]} = params,
        socket
      ) do
    picked =
      case params["value-" <> uuid] do
        %{"values" => values} -> values
        _emptied -> []
      end

    {:noreply, put_value(socket, uuid, picked)}
  end

  # Nothing is applied while a row holds a value its field cannot take: the
  # read would refuse the whole tree, and the visitor could not tell which row
  # it was. Each such row says so under itself instead.
  def handle_event("apply_filter", _, socket) do
    %{custom_filter: custom_filter, fields: fields} = socket.assigns
    errors = value_errors(custom_filter, fields, socket.assigns.timezone)

    if errors == %{}, do: notify_parent(custom_filter)

    {:noreply, assign(socket, :value_errors, errors)}
  end

  def handle_event("reset", _, socket) do
    notify_parent(nil)
    {:noreply, assign(socket, :value_errors, %{})}
  end

  defp put_value(socket, uuid, value) do
    value = held_value(socket, uuid, value)
    custom_filter = CustomFilter.update_filter(socket.assigns.custom_filter, uuid, :value, value)

    socket |> assign(:custom_filter, custom_filter) |> forget_error(uuid)
  end

  # The options of the row whose LiveSelect has `id`, narrowed to the labels
  # holding `search`. An id no row has now is a stale page, and is ignored.
  defp offer_values(socket, id, search) do
    %{custom_filter: custom_filter, fields: fields} = socket.assigns

    with %CustomFilter{field_name: name, value: value} <-
           custom_filter |> CustomFilter.leaves() |> Enum.find(&(picker_id(&1) == id)),
         %FilterField{field: field, resource: resource} <- field_for(fields, name) do
      {options, _labels} = value_choices(field, resource, held_values(value))
      send_update(LiveSelect.Component, id: id, options: EnumOptions.search(options, search))
    end

    socket
  end

  # An error answers the value it was found on, so it goes once the row is
  # edited, rather than standing under a value it no longer describes.
  defp forget_error(socket, uuid), do: forget_errors(socket, [uuid])

  defp forget_errors(socket, uuids),
    do: assign(socket, :value_errors, Map.drop(socket.assigns.value_errors, uuids))

  # Each row whose value its field's type will not cast, by uuid, with the
  # message to show under it. Asked with `Ash.Type.coerce/3`, which is what
  # Ash casts a filter's values with, so the form refuses only what the read
  # would: `cast_input/3` differs for some types, an atom among them, which it
  # accepts only when the VM already knows it.
  #
  # A row with no value is left out of the filter, so it is not checked. Nor
  # is one on a field the form does not offer, which only a link carries: the
  # read decides that one, and drops the filter with a flash if it fails.
  defp value_errors(filter, fields, timezone) do
    for %CustomFilter{uuid: uuid, field_name: name, operator: operator, value: value} <-
          CustomFilter.applied_leaves(filter),
        %FilterField{field: field} <- [field_for(fields, name)],
        message = cast_error(field, operator, value, timezone),
        not is_nil(message),
        into: %{},
        do: {uuid, message}
  end

  defp cast_error(field, operator, value, timezone) do
    case CustomFilter.cast_row_value(field, operator, value, timezone) do
      {:ok, _} -> nil
      {:error, error} -> error_message(error)
    end
  end

  # Worded the way a form words a field's error, and translated through the
  # same `:error_translator`.
  defp error_message(error) do
    {message, vars} =
      case error do
        message when is_binary(message) -> {message, []}
        [_ | _] = keyword -> {Keyword.get(keyword, :message, "is invalid"), keyword}
        %{message: message, vars: vars} when is_binary(message) -> {message, vars || []}
        error when is_exception(error) -> {Exception.message(error), []}
        _ -> {"is invalid", []}
      end

    ActionErrors.translate(message, Enum.reject(vars, &match?({:message, _}, &1)))
  end

  # The offered field a row names, or `nil` for one the form does not offer.
  defp field_for(fields, name), do: Enum.find(fields, &(&1.name == name))

  # A timestamp is typed in the zone the list shows it in, and held as the UTC
  # instant that means. See `AshQuick.LiveView.LocalDatetime`. On Day holds
  # its date as typed, and reads it in that zone when the filter is built.
  defp held_value(socket, uuid, value) do
    case CustomFilter.find(socket.assigns.custom_filter, uuid) do
      %CustomFilter{field_name: name, operator: operator} ->
        field =
          with %FilterField{field: field} <- field_for(socket.assigns.fields, name), do: field

        hold(CustomFilter.value_shape(operator), field, value, socket.assigns.timezone)

      nil ->
        value
    end
  end

  # Any Of's and Has Any Of's LiveSelect sends a list, `[]` once its last
  # value is removed; their text input, on a field without a fixed set, one
  # string.
  defp hold(:list, field, value, timezone) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&hold(:scalar, field, &1, timezone))
  end

  defp hold(:list, _field, value, _timezone), do: List.wrap(value)

  defp hold(:scalar, %{type: type}, value, timezone) when type in @datetime_types,
    do: LocalDatetime.to_utc(value, timezone)

  defp hold(_shape, _field, value, _timezone), do: value

  # Asked only when what it depends on changed, rather than on every render,
  # event or re-render of the modal: a field policy is a check against the
  # actor, and the answer does not change while the form is open.
  defp assign_fields(socket) do
    if Enum.any?([:resource, :filterable, :action, :scope], &changed?(socket, &1)) do
      %{resource: resource, filterable: filterable, action: action, scope: scope} =
        socket.assigns

      # Without the list's read, the field policies are asked against the
      # resource's primary read, so a caller that names none still hides them.
      action = action || Ash.Resource.Info.primary_action(resource, :read)
      fields = CustomFilter.offered_fields(resource, filterable, action, scope)

      socket
      |> assign(:fields, fields)
      |> assign(:emptiable, emptiable(fields, action, scope))
    else
      socket
    end
  end

  # The fields Is Empty and Is Not Empty are offered on: ones that can be
  # empty, and that the actor sees on every row. Ash reads a field as `nil`
  # where a field policy hides it, so Is Empty would keep a row whose value
  # the actor may not see as one that has none.
  defp emptiable(fields, action, scope) do
    fields
    |> Enum.filter(&emptiable?/1)
    |> CustomFilter.visible(action, scope, filter_is: false)
    |> MapSet.new(& &1.name)
  end

  # A row can name a field this form does not offer: a link written for an
  # actor who could see it, or by hand. The select holds it as a disabled
  # option, so it shows the field the row filters on instead of the first one
  # offered, which a browser would show and could not then be picked.
  defp field_options(fields, field_name, labels, resource) do
    options = Enum.map(fields, &{field_label(&1.name, labels, resource), &1.name})

    if is_binary(field_name) and not Enum.any?(options, &(elem(&1, 1) == field_name)),
      do: [
        [key: field_label(field_name, labels, resource), value: field_name, disabled: true]
        | options
      ],
      else: options
  end

  @doc """
  What a field of `resource` is called, here and on the list's chips: its
  column's label when the list shows one, and otherwise the label the resource
  declares for it or its humanized name. A field reached through a
  relationship reads as both, "Brand › Name", whatever its column is called:
  a column through `brand` is often labelled by the field alone, which would
  read as one of the list's own.
  """
  def field_label(name, labels, resource \\ nil)

  def field_label(name, labels, resource) when is_binary(name) do
    cond do
      FilterField.path?(name) -> FilterField.path_label(name, resource)
      label = labels[name] -> label
      true -> name |> FilterField.known_atom() |> Labels.name(resource)
    end
  end

  def field_label(name, labels, resource), do: field_label(to_string(name), labels, resource)

  # A new row starts on the first field offered: no one field is one every
  # resource has, or one every actor may see.
  defp first_leaf([%FilterField{name: name, field: field} | _]),
    do: %{field_name: name, operator: first_operator(field)}

  defp first_leaf([]), do: nil

  # Is Empty is never first: a row starts comparing its field with a value.
  defp first_operator(field), do: field |> base_operators() |> List.first()

  @doc """
  What `operator` reads as, here and on the list's chips. One a link names that
  this form never offers reads as written.
  """
  def operator_label("equals"), do: "="
  def operator_label("not_equals"), do: "!="
  def operator_label("gt"), do: ">"
  def operator_label("gte"), do: ">="
  def operator_label("lt"), do: "<"
  def operator_label("lte"), do: "<="
  def operator_label("contains"), do: gettext("Contains")
  def operator_label("not_contains"), do: gettext("Not Contains")
  def operator_label("starts_with"), do: gettext("Starts With")
  def operator_label("ends_with"), do: gettext("Ends With")
  def operator_label("in"), do: gettext("Any Of")
  def operator_label("has_any"), do: gettext("Has Any Of")
  def operator_label("on"), do: gettext("On Day")
  def operator_label("is_nil"), do: gettext("Is Empty")
  def operator_label("is_not_nil"), do: gettext("Is Not Empty")
  def operator_label(operator), do: operator

  @doc """
  What `operator` reads as in the middle of a chip's sentence ("Code starts
  with A"), where the form's title case would read oddly.
  """
  def operator_phrase("contains"), do: gettext("contains")
  def operator_phrase("not_contains"), do: gettext("does not contain")
  def operator_phrase("starts_with"), do: gettext("starts with")
  def operator_phrase("ends_with"), do: gettext("ends with")
  def operator_phrase("in"), do: gettext("is any of")
  def operator_phrase("has_any"), do: gettext("has any of")
  def operator_phrase("on"), do: pgettext("filter chip", "on")
  def operator_phrase("is_nil"), do: gettext("is empty")
  def operator_phrase("is_not_nil"), do: gettext("is not empty")
  def operator_phrase(operator), do: operator_label(operator)

  @equality ~w(equals not_equals)
  @comparisons ~w(gt gte lt lte)
  @emptiness ~w(is_nil is_not_nil)

  # The operators a row on `field` offers, each with its label. A row's own
  # operator is offered too when its field does not, as Any Of a link names
  # on a field without a fixed set, so the select shows what the row does.
  defp operator_options(field, operator, emptiable) do
    operators = field_operators(field, emptiable)

    operators =
      if is_binary(operator) and operator not in operators,
        do: operators ++ [operator],
        else: operators

    Enum.map(operators, &{operator_label(&1), &1})
  end

  # A field is also asked whether it is empty when it can be, and the actor
  # sees it on every row.
  defp field_operators(nil, _emptiable), do: []

  defp field_operators(%FilterField{name: name, field: field}, emptiable) do
    operators = base_operators(field)

    if operators != [] and name in emptiable,
      do: operators ++ @emptiness,
      else: operators
  end

  # A field with a fixed set of values compares by value, whatever its type,
  # or against several, and a list of such values by whether it holds any of
  # several; anything else by what its type allows.
  defp base_operators(field) do
    case EnumOptions.kind(field) do
      :single -> @equality ++ ["in"]
      :array -> ["has_any"]
      nil -> type_operators(field)
    end
  end

  # A field reached through a belongs_to that may be unset is empty on a row
  # that has no related record, whether or not the related field can be.
  defp emptiable?(%FilterField{relationship: %{allow_nil?: true}}), do: true
  defp emptiable?(%FilterField{field: field}), do: nullable?(field)

  # A count, or whether any row exists, is never `nil`, nor is an aggregate
  # with a `default`. Another aggregate is when it finds nothing, and names no
  # `allow_nil?` to say otherwise. A list can hold nothing, which reads as
  # empty, even where it is never `nil`.
  defp nullable?(%Ash.Resource.Aggregate{kind: kind}) when kind in [:count, :exists], do: false
  defp nullable?(%Ash.Resource.Aggregate{default: default}) when not is_nil(default), do: false
  defp nullable?(%{type: {:array, _type}}), do: true
  defp nullable?(field), do: Map.get(field, :allow_nil?, true)

  defp type_operators(%{type: t})
       when t in [Ash.Type.UUID, Ash.Type.UUIDv7, Ash.Type.Atom, Ash.Type.Boolean],
       do: @equality

  defp type_operators(%{type: t}) when t in [Ash.Type.String, Ash.Type.CiString],
    do: @equality ++ ~w(contains not_contains starts_with ends_with)

  defp type_operators(%{type: t})
       when t in [Ash.Type.Date, Ash.Type.Integer, Ash.Type.Decimal],
       do: @equality ++ @comparisons

  defp type_operators(%{type: t}) when t in @datetime_types, do: @comparisons ++ ["on"]

  defp type_operators(%{type: Ash.Type.Float}), do: @comparisons

  defp type_operators(_field), do: []

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
