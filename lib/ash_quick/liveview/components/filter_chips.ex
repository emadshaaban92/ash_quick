defmodule AshQuick.LiveView.Components.FilterChips do
  @moduledoc false
  use Phoenix.Component
  use Gettext, backend: AshQuick.Gettext
  import AshQuick.Components, only: [icon: 1]

  alias AshQuick.Labels
  alias AshQuick.LiveView.Components.FieldValue
  alias AshQuick.LiveView.Components.FilterForm
  alias AshQuick.LiveView.CustomFilter
  alias AshQuick.LiveView.FilterField
  alias AshQuick.LiveView.FilterRecords
  alias AshQuick.LiveView.MapFilter
  alias AshQuick.LiveView.QuickField
  alias AshQuick.LiveView.URLParams

  @doc """
  The applied filter as chips above the list, so a filtered list does not pass
  for the whole one. Each top-level row is a chip whose ✕ drops it; a group of
  rows is one chip that opens the modal, since a group's rows only mean
  something together. Nothing renders without a filter.

  Read from the params the page was built from, so a row dropped before the
  read (a hidden field, or a filter the read refused) has no chip. A record
  row's chip names the records it holds, as `records` gives them; without
  it, they are read here, in one query per row's field through the
  destination's lookup action with the reader's scope.
  """
  attr :resource, :atom, required: true
  attr :params, :map, required: true
  attr :path, :string, required: true
  attr :scope, :any, default: nil, doc: "the reader's scope, whose zone a timestamp reads in"

  attr :records, :map,
    default: nil,
    doc:
      "the options naming the records each record row holds, by field name and id, as " <>
        "`AshQuick.LiveView.FilterRecords.held_by_field/3` reads them where the list is read"

  attr :columns, :list,
    default: [],
    doc: "the list's `QuickField`s, whose labels name a chip's field as its column does"

  def filter_chips(%{params: %URLParams{custom_filter: %CustomFilter{} = filter}} = assigns) do
    %{resource: resource, params: params, scope: scope} = assigns

    assigns =
      assign(assigns,
        filter: filter,
        chips: CustomFilter.chips(filter),
        fields: CustomFilter.fields_by_name(resource, params.filterable),
        labels: column_labels(assigns.columns),
        records: assigns.records || FilterRecords.held_by_field(resource, params, scope)
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
        resource={@resource}
        fields={@fields}
        labels={@labels}
        records={@records}
        params={@params}
        path={@path}
        scope={@scope}
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

  @doc "The list's column labels, as drawn, by the field name a filter row holds."
  def column_labels(columns), do: Map.new(columns, &{QuickField.data_field(&1), Labels.field(&1)})

  # A group holding one row reads as that row, but its ✕ drops the group: the
  # row's `and` or `or` is the group's, and with one row it changes nothing.
  # A group of several says whether all its rows must hold or any one will do,
  # since a chip that read the same either way would make an `or` look stricter
  # than it is.
  attr :node, CustomFilter, required: true
  attr :resource, :atom, required: true
  attr :fields, :map, required: true
  attr :labels, :map, required: true
  attr :records, :map, default: %{}
  attr :params, :map, required: true
  attr :path, :string, required: true
  attr :scope, :any, default: nil

  defp chip(%{node: %CustomFilter{children: [_ | _]} = group} = assigns) do
    case CustomFilter.applied_leaves(group) do
      [leaf] ->
        assigns = assign(assigns, :leaf, leaf)

        ~H"""
        <.chip_box
          node={@node}
          leaf={@leaf}
          resource={@resource}
          fields={@fields}
          labels={@labels}
          records={@records}
          params={@params}
          path={@path}
          scope={@scope}
        />
        """

      leaves ->
        assigns = assign(assigns, :count, length(leaves))

        ~H"""
        <.chip_box node={@node} params={@params} path={@path}>
          <button type="button" phx-click="open_custom_filter" class="hover:underline">
            <%= if @node.operator == "or" do %>
              {ngettext("Any of %{count} condition", "Any of %{count} conditions", @count)}
            <% else %>
              {ngettext("All of %{count} condition", "All of %{count} conditions", @count)}
            <% end %>
          </button>
        </.chip_box>
        """
    end
  end

  defp chip(assigns) do
    ~H"""
    <.chip_box
      node={@node}
      leaf={@node}
      resource={@resource}
      fields={@fields}
      labels={@labels}
      records={@records}
      params={@params}
      path={@path}
      scope={@scope}
    />
    """
  end

  # The ✕ is a button naming its node, which the list drops from the filter
  # it holds, rather than a link holding the rest of the filter: one such
  # link per chip repeats the whole filter on the page once per row.
  #
  # The ✕ is named by the chip's own words, so a screen reader listing the
  # page's links hears which filter each one removes rather than the same
  # "Remove filter" for all of them. A long value wraps inside the chip rather
  # than running past the card, which would clip it and its ✕.
  attr :node, CustomFilter, required: true
  attr :leaf, CustomFilter, default: nil
  attr :resource, :atom, default: nil
  attr :fields, :map, default: %{}
  attr :labels, :map, default: %{}
  attr :records, :map, default: %{}
  attr :params, :map, required: true
  attr :path, :string, required: true
  attr :scope, :any, default: nil
  slot :inner_block

  defp chip_box(assigns) do
    assigns =
      assign(assigns,
        id: "ash-quick-filter-chip-#{assigns.node.uuid}",
        label: assigns.leaf && leaf_label(assigns.leaf, assigns.labels, assigns.resource),
        field: assigns.leaf && assigns.fields[assigns.leaf.field_name]
      )

    ~H"""
    <span
      class="badge badge-lg badge-soft badge-primary h-auto min-h-8 max-w-full gap-1 py-1 pe-1"
      data-filter-chip={if @leaf, do: @leaf.field_name, else: "group"}
    >
      <span id={"#{@id}-text"} class="min-w-0 break-words">
        <%= if @leaf do %>
          {@label}
          <.chip_value
            leaf={@leaf}
            field={@field && @field.field}
            filter_field={@field}
            records={@records[@leaf.field_name] || %{}}
            resource={(@field && @field.resource) || @resource}
            scope={@scope}
          />
        <% else %>
          {render_slot(@inner_block)}
        <% end %>
      </span>
      <span id={"#{@id}-remove"} hidden>{gettext("Remove filter")}</span>
      <button
        type="button"
        phx-click="remove_filter_chip"
        phx-value-node={@node.uuid}
        class="btn btn-ghost btn-xs btn-circle shrink-0"
        aria-labelledby={"#{@id}-remove #{@id}-text"}
        data-remove-filter
      >
        <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
      </button>
    </span>
    """
  end

  # "Price >", "Code starts with", "Brand › Name contains": the field as its
  # column names it, or as the form does when the list shows no column for it
  # or reaches it through a relationship, and its operator. A map row names
  # its key path too: "Changes › price › to >", "Changes › any key contains".
  defp leaf_label(%CustomFilter{field_name: name, operator: operator} = leaf, labels, resource),
    do:
      "#{field_label(leaf, FilterForm.field_label(name, labels, resource))} #{FilterForm.operator_phrase(operator)}"

  defp field_label(%CustomFilter{path: path}, label) when is_list(path),
    do: MapFilter.path_label(label, path)

  defp field_label(_leaf, label), do: label

  # The value reads as `FieldValue` renders one of its field, as a column with
  # no widget of its own shows it, labelled by the resource holding the
  # field: Yes or No, an enum's label, a timestamp in the list's zone, On
  # Day's date as the list shows a date. A column's widget is not used: it is
  # handed the row's record, which a chip has none of. One its field's type
  # will not take, which only a link carries, or one on a field the resource
  # does not have, reads as written.
  attr :leaf, CustomFilter, required: true
  attr :field, :any, required: true
  attr :filter_field, :any, default: nil
  attr :records, :map, default: %{}
  attr :resource, :atom, default: nil
  attr :scope, :any, default: nil

  # Is Empty and Is Not Empty compare with nothing, and so do a map row's Key
  # Exists and Key Missing, so their phrase is the whole chip.
  defp chip_value(%{leaf: %{operator: operator}} = assigns)
       when operator in ~w(is_nil is_not_nil has_key missing_key) do
    ~H""
  end

  # A record row names the records it holds, as a relationship dropdown
  # labels them, and a placeholder for one the reader may not read.
  defp chip_value(%{filter_field: %FilterField{record?: true}, leaf: %{value: value}} = assigns) do
    ids = for id <- List.wrap(value), is_binary(id) and id != "", uniq: true, do: id

    assigns =
      assign(
        assigns,
        :names,
        Enum.map(ids, &(assigns.records[&1] || FilterRecords.unavailable(&1)).label)
      )

    ~H"""
    <span class="font-semibold" dir="auto">{Enum.join(@names, ", ")}</span>
    """
  end

  # A map row's value is compared with whatever the map holds, of any type,
  # so it reads as typed.
  defp chip_value(%{leaf: %{path: path}} = assigns) when is_list(path) do
    ~H"""
    <span class="font-semibold" dir="auto">{CustomFilter.as_written(@leaf.value)}</span>
    """
  end

  # Any Of and Has Any Of read their values one after another, each as its
  # field renders one. Numbers are kept apart by a semicolon: a comma is
  # the digit grouping or the decimal mark of some locale, so `1,000, 2,000`
  # could be read as more or fewer numbers than there are.
  defp chip_value(
         %{field: %{type: type} = field, leaf: %{operator: operator, value: value}} = assigns
       )
       when not is_nil(type) do
    case CustomFilter.cast_row_value(
           field,
           operator,
           value,
           AshQuick.Scope.timezone(assigns.scope)
         ) do
      {:ok, cast} when cast not in [nil, []] ->
        items = if CustomFilter.value_shape(operator) == :list, do: cast, else: [cast]

        assigns =
          assigns
          |> assign(:items, items)
          |> assign(:separator, if(Enum.any?(items, &number?/1), do: "; ", else: ", "))

        ~H"""
        <span class="font-semibold"><span :for={{item, i} <- Enum.with_index(@items)}><span :if={i != 0}>{@separator}</span><FieldValue.field_value
          value={item}
          path={[]}
          ash_field={@field}
          resource={@resource}
          scope={@scope}
        /></span></span>
        """

      _ ->
        assigns |> assign(:field, nil) |> chip_value()
    end
  end

  defp chip_value(assigns) do
    ~H"""
    <span class="font-semibold">{CustomFilter.as_written(@leaf.value)}</span>
    """
  end

  defp number?(value), do: is_number(value) or is_struct(value, Decimal)
end
