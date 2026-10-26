defmodule AshQuick.LiveView.Components.FilterChips do
  @moduledoc false
  use Phoenix.Component
  use Gettext, backend: AshQuick.Gettext
  import AshQuick.Components, only: [icon: 1]

  alias AshQuick.LiveView.Components.FieldValue
  alias AshQuick.LiveView.Components.FilterForm
  alias AshQuick.LiveView.CustomFilter
  alias AshQuick.LiveView.QuickField
  alias AshQuick.LiveView.URLParams

  @doc """
  The applied filter as chips above the list, so a filtered list does not pass
  for the whole one. Each top-level row is a chip whose ✕ drops it; a group of
  rows is one chip that opens the modal, since a group's rows only mean
  something together. Nothing renders without a filter.

  Read from the params the page was built from, so a row dropped before the
  read (a hidden field, or a filter the read refused) has no chip.
  """
  attr :resource, :atom, required: true
  attr :params, :map, required: true
  attr :path, :string, required: true

  attr :columns, :list,
    default: [],
    doc: "the list's `QuickField`s, whose labels name a chip's field as its column does"

  def filter_chips(%{params: %URLParams{custom_filter: %CustomFilter{} = filter}} = assigns) do
    assigns =
      assign(assigns,
        filter: filter,
        chips: CustomFilter.chips(filter),
        fields: CustomFilter.fields_by_name(assigns.resource),
        labels: column_labels(assigns.columns)
      )

    ~H"""
    <div
      :if={@chips != []}
      id="ash-quick-filter-chips"
      class="flex flex-wrap items-center gap-2 px-4 pb-4"
    >
      <span :if={@filter.operator == "or" and length(@chips) > 1} class="text-sm opacity-70">
        {gettext("Any of:")}
      </span>
      <.chip
        :for={node <- @chips}
        node={node}
        fields={@fields}
        labels={@labels}
        params={@params}
        path={@path}
      />
      <.link
        :if={length(@chips) > 1}
        id="ash-quick-filter-clear"
        patch={URLParams.full_path(@path, URLParams.change_custom_filter(@params, nil))}
        class="btn btn-ghost btn-xs"
      >
        {gettext("Clear all")}
      </.link>
    </div>
    """
  end

  def filter_chips(assigns), do: ~H""

  @doc "The list's column labels by the field name a filter row holds."
  def column_labels(columns), do: Map.new(columns, &{QuickField.data_field(&1), &1.label})

  # A group holding one row reads as that row, but its ✕ drops the group: the
  # row's `and` or `or` is the group's, and with one row it changes nothing.
  # A group of several says whether all its rows must hold or any one will do,
  # since a chip that read the same either way would make an `or` look stricter
  # than it is.
  attr :node, CustomFilter, required: true
  attr :fields, :map, required: true
  attr :labels, :map, required: true
  attr :params, :map, required: true
  attr :path, :string, required: true

  defp chip(%{node: %CustomFilter{children: [_ | _]} = group} = assigns) do
    case CustomFilter.applied_leaves(group) do
      [leaf] ->
        assigns = assign(assigns, :leaf, leaf)

        ~H"""
        <.chip_box
          node={@node}
          leaf={@leaf}
          fields={@fields}
          labels={@labels}
          params={@params}
          path={@path}
        />
        """

      leaves ->
        assigns = assign(assigns, :count, length(leaves))

        ~H"""
        <.chip_box node={@node} params={@params} path={@path}>
          <.link
            patch={URLParams.full_path(@path, URLParams.toggle_show_custom_filter(@params))}
            class="hover:underline"
          >
            <%= if @node.operator == "or" do %>
              {ngettext("Any of %{count} condition", "Any of %{count} conditions", @count)}
            <% else %>
              {ngettext("All of %{count} condition", "All of %{count} conditions", @count)}
            <% end %>
          </.link>
        </.chip_box>
        """
    end
  end

  defp chip(assigns) do
    ~H"""
    <.chip_box
      node={@node}
      leaf={@node}
      fields={@fields}
      labels={@labels}
      params={@params}
      path={@path}
    />
    """
  end

  # The ✕ is named by the chip's own words, so a screen reader listing the
  # page's links hears which filter each one removes rather than the same
  # "Remove filter" for all of them. A long value wraps inside the chip rather
  # than running past the card, which would clip it and its ✕.
  attr :node, CustomFilter, required: true
  attr :leaf, CustomFilter, default: nil
  attr :fields, :map, default: %{}
  attr :labels, :map, default: %{}
  attr :params, :map, required: true
  attr :path, :string, required: true
  slot :inner_block

  defp chip_box(assigns) do
    assigns =
      assign(assigns,
        id: "ash-quick-filter-chip-#{assigns.node.uuid}",
        label: assigns.leaf && leaf_label(assigns.leaf, assigns.labels),
        field: assigns.leaf && assigns.fields[assigns.leaf.field_name]
      )

    ~H"""
    <span
      class="badge badge-lg badge-soft badge-primary h-auto min-h-8 max-w-full gap-1 py-1 pe-1"
      data-filter-chip={if @leaf, do: @leaf.field_name, else: "group"}
    >
      <span id={"#{@id}-text"} class="min-w-0 break-words">
        <%= if @leaf do %>
          {@label} <.chip_value leaf={@leaf} field={@field} />
        <% else %>
          {render_slot(@inner_block)}
        <% end %>
      </span>
      <span id={"#{@id}-remove"} hidden>{gettext("Remove filter")}</span>
      <.link
        patch={
          URLParams.full_path(
            @path,
            URLParams.change_custom_filter(
              @params,
              CustomFilter.without(@params.custom_filter, @node.uuid)
            )
          )
        }
        class="btn btn-ghost btn-xs btn-circle shrink-0"
        aria-labelledby={"#{@id}-remove #{@id}-text"}
        data-remove-filter
      >
        <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
      </.link>
    </span>
    """
  end

  # "Price >", "Code starts with": the field as its column names it, or as
  # the form does when the list shows no column for it, and its operator.
  defp leaf_label(%CustomFilter{field_name: name, operator: operator}, labels),
    do: "#{FilterForm.field_label(name, labels)} #{FilterForm.operator_phrase(operator)}"

  # The value reads as `FieldValue` renders one of its field, as a column with
  # no widget of its own shows it: Yes or No, an enum's label, a timestamp in
  # the list's zone. A column's widget is not used: it is handed the row's
  # record, which a chip has none of. One its field's type will not take,
  # which only a link carries, or one on a field the resource does not have,
  # reads as written.
  attr :leaf, CustomFilter, required: true
  attr :field, :any, required: true

  defp chip_value(%{field: %{type: type} = field, leaf: %{value: value}} = assigns)
       when not is_nil(type) do
    case CustomFilter.cast_value(field, value) do
      {:ok, cast} when not is_nil(cast) ->
        assigns = assign(assigns, :cast, cast)

        ~H"""
        <span class="font-semibold">
          <FieldValue.field_value value={@cast} path={[]} ash_field={@field} />
        </span>
        """

      _ ->
        assigns |> assign(:field, nil) |> chip_value()
    end
  end

  defp chip_value(assigns) do
    ~H"""
    <span class="font-semibold">{as_written(@leaf.value)}</span>
    """
  end

  # A link's value can be any JSON: a list, as `in` takes, would otherwise
  # render as iodata, which raises for most lists.
  defp as_written(value) when is_binary(value), do: value
  defp as_written(value) when is_list(value), do: Enum.map_join(value, ", ", &as_written/1)

  defp as_written(value) when is_number(value) or is_atom(value) or is_boolean(value),
    do: to_string(value)

  defp as_written(value), do: inspect(value)
end
