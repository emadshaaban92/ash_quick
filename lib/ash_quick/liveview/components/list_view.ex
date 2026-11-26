defmodule AshQuick.LiveView.Components.ListView do
  @moduledoc false
  use Phoenix.Component
  use Gettext, backend: AshQuick.Gettext
  import AshQuick.Components
  alias AshQuick.Labels
  alias Phoenix.LiveView.JS

  import AshQuick.LiveView.Components.FieldValue

  alias AshQuick.LiveView.Utils
  alias AshQuick.LiveView.QuickField
  alias AshQuick.LiveView.URLParams
  alias AshQuick.LiveView.Components.ActionModal
  alias AshQuick.LiveView.Components.Menu
  alias AshQuick.LiveView.Components.FilterChips
  alias AshQuick.LiveView.CellFilter
  alias AshQuick.LiveView.CustomFilter

  attr(:id, :string, required: true)
  attr(:resource, :map, required: true)
  attr(:new_action_label, :string, default: nil)
  attr(:new_click, :any, default: nil, doc: "the function for handling phx-click on new button")
  attr(:fields, :list, required: true)

  attr(:data, :map,
    required: true,
    doc: "the page `keep_live/4` read: its `results`, `count`, `limit` and `offset`"
  )

  attr(:row_css_class, :any,
    default: nil,
    doc: "the function for adding extra css classes on each row"
  )

  attr(:row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"
  )

  attr(:scope, :map, required: true)

  attr(:ash_action, :map,
    default: nil,
    doc: "the read the list runs, which field policies are asked against"
  )

  attr(:params, :map, default: nil)

  attr(:path_for_page, :any, default: nil, doc: "the function for generating pagination paths")

  attr(:sortable, :list,
    default: [],
    doc: "the `QuickField.data_field/1` names of the columns the list may be sorted by"
  )

  attr(:actions, :any, default: nil)
  attr(:filters, :map, default: nil)
  attr(:selected_rows, :map, default: nil)
  attr(:action_running, :boolean, default: false)

  attr(:row_order, :list,
    default: nil,
    doc: "the ids drawn, in the order drawn, placeholders among them; `nil` draws `@data.results`"
  )

  attr(:gone_rows, :any,
    default: MapSet.new(),
    doc: "a `MapSet` of the ids drawn as \"No longer available\" placeholders"
  )

  attr(:list_news, :boolean,
    default: false,
    doc: "whether records not on screen now belong on the page, which shows the Reload bar"
  )

  attr(:cell_menu, :map,
    default: nil,
    doc:
      "`%{id: record_id, column: data_field, choices: [choice]}` for the cell whose filter menu was last opened"
  )

  attr(:cell_filters, :map,
    default: %{},
    doc:
      "each column whose cells offer to filter the list by their value, by `QuickField.data_field/1`, as `CellFilter.columns/4` gives it"
  )

  attr(:number_columns, :list,
    default: [],
    doc:
      "the columns holding numbers, by `QuickField.data_field/1`, drawn against the column's right edge, as `NumberColumns.columns/2` gives them"
  )

  attr(:row_actions, :map,
    default: nil,
    doc: "`%{id: record_id, actions: [action]}` for the row whose menu was last opened"
  )

  # Read as `assigns[:flash]`, which change tracking follows as it does
  # `@flash`, so a list drawn without it draws no flash rather than raising.
  attr(:flash, :map,
    doc: "the page's flash, which the filter and export modals draw while they are open"
  )

  # Called with the LiveView's own assigns, so `__changed__` here is the
  # socket's. A key assigned in this function is one the socket never holds:
  # the next render finds it absent again and change tracking marks it changed
  # every time, re-rendering everything that reads it — the rows, the pager and
  # the actions menu — on every event. So nothing is assigned here. What the
  # template derives from `@data`, `@params` and `@actions` it derives inline,
  # where it is tracked through them and re-rendered only when one changes.
  def list_view(assigns) do
    ~H"""
    <section id={"#{@id}-menus"} class="bg-base-200 p-3 sm:p-5" phx-hook={Menu.hook()}>
      <div class="mx-auto max-w-full">
        <div class="card bg-base-100 shadow-md overflow-hidden">
          <div class="flex flex-col lg:flex-row items-center justify-between space-y-3 lg:space-y-0 lg:space-x-4 p-4">
            <div class="w-full lg:w-1/2 flex flex-col sm:flex-row space-y-2 sm:space-y-0 items-stretch sm:items-center sm:space-x-3">
              <.custom_filter_modal
                :if={@params.show_custom_filter}
                resource={@resource}
                action={@ash_action}
                scope={@scope}
                params={@params}
                path={@path}
                columns={@fields}
                filterable={@params.filterable}
                flash={assigns[:flash] || %{}}
                held_filter={assigns[:held_filter]}
              />

              <div class="flex items-center w-full space-x-2">
                <div class="flex-1">
                  <.search_form params={@params} />
                </div>
                <.filter_button :if={@params.filterable != []} params={@params} path={@path} />
              </div>
            </div>
            <div class="w-full lg:w-auto flex flex-col sm:flex-row space-y-2 sm:space-y-0 items-stretch sm:items-center justify-end sm:space-x-3 shrink-0">
              <.new_button
                :if={:create in @routed_shapes and create_offered?(@resource, @scope)}
                new_click={@new_click}
                new_action_label={@new_action_label}
              />
              <div class="flex items-center space-x-3 w-full sm:w-auto">
                <.export_menu :if={AshQuick.Config.exports_enabled?()} />
                <.actions_menu
                  filtered_actions={present_actions(@actions)}
                  action_running={@action_running}
                  selected_rows={@selected_rows}
                />
                <.filters_menu filters={@filters} params={@params} />
              </div>
            </div>
          </div>
          <FilterChips.filter_chips
            resource={@resource}
            params={@params}
            path={@path}
            scope={@scope}
            columns={@fields}
            records={assigns[:filter_records]}
          />
          <div
            :if={@list_news}
            id="list-news"
            role="status"
            class="alert alert-info alert-soft mx-4 mb-3 flex flex-wrap items-center justify-between gap-2"
          >
            <span>{gettext("This list has new records.")}</span>
            <button type="button" phx-click="reload_list" class="btn btn-sm">
              {gettext("Reload")}
            </button>
          </div>
          <.form for={%{}} id="table-form" phx-change="table-form-change">
            <div class="overflow-x-auto min-h-[20rem] lg:min-h-[30rem]">
              <table
                id={"#{@id}-table"}
                class="table table-sm text-base-content"
              >
                <thead>
                  <tr>
                    <th :if={@selected_rows} class="w-4">
                      <span class="sr-only">{gettext("Select")}</span>
                      <input
                        id="select_row_all"
                        name="all"
                        type="checkbox"
                        aria-label={gettext("Select all rows")}
                        checked={@selected_rows["all"] == "on"}
                        class="checkbox checkbox-sm bg-base-300 text-base-content"
                      />
                    </th>
                    <th
                      :for={field <- @fields}
                      aria-sort={aria_sort(@params, QuickField.data_field(field))}
                      class={QuickField.data_field(field) in @number_columns && "text-right"}
                    >
                      <.sort_header
                        :if={QuickField.data_field(field) in @sortable}
                        field={field}
                        params={@params}
                        path={@path}
                      />
                      <span :if={QuickField.data_field(field) not in @sortable}>
                        {Labels.field(field)}
                      </span>
                    </th>
                    <th>
                      <span class="sr-only">{gettext("Actions")}</span>
                    </th>
                  </tr>
                </thead>
                <tbody id={@id}>
                  <tr
                    :for={{kind, row} <- screen_rows(@data.results, @row_order, @gone_rows)}
                    id={row.id}
                    :key={row.id}
                    data-gone={kind == :gone}
                    class={
                      if kind == :gone,
                        do: "text-base-content/60",
                        else: [
                          @row_css_class && @row_css_class.(row),
                          AshQuick.Info.inactive?(row) && "opacity-50"
                        ]
                    }
                  >
                    <%= if kind == :gone do %>
                      <td :if={@selected_rows} class="w-4"></td>
                      <td colspan={length(@fields) + 1} class="italic">
                        {gettext("No longer available")}
                      </td>
                    <% else %>
                      <td :if={@selected_rows} class="w-4">
                        <input
                          id={"select_row_#{row.id}"}
                          name={"#{row.id}"}
                          type="checkbox"
                          aria-label={row_checkbox_label(row)}
                          checked={@selected_rows[row.id] == "on"}
                          class="checkbox checkbox-sm bg-base-300 text-base-content"
                        />
                      </td>
                      <td
                        :for={{field, column} <- Enum.with_index(@fields)}
                        class={[
                          @cell_filters[QuickField.data_field(field)] && "group/cell relative pe-7",
                          QuickField.data_field(field) in @number_columns &&
                            "text-right tabular-nums"
                        ]}
                        tabindex={@cell_filters[QuickField.data_field(field)] && "-1"}
                      >
                        <.render_field
                          field={field}
                          record={row}
                          scope={@scope}
                          linker={@linker}
                        />
                        <.cell_filter_menu
                          :if={@cell_filters[QuickField.data_field(field)]}
                          record={row}
                          field={field}
                          column_filter={@cell_filters[QuickField.data_field(field)]}
                          cell_menu={@cell_menu}
                          toward_start={column >= div(length(@fields), 2)}
                          scope={@scope}
                        />
                      </td>
                      <td>
                        <div class="flex items-center justify-end">
                          <.link
                            patch={
                              URLParams.full_path(
                                @base_path,
                                @params |> URLParams.to_details_params(row.id)
                              )
                            }
                            class="btn btn-ghost btn-xs btn-square"
                          >
                            <span class="sr-only">{gettext("View details")}</span>
                            <.icon name="hero-eye" class="w-5 h-5" />
                          </.link>

                          <.record_actions record={row} row_actions={@row_actions} />
                        </div>
                      </td>
                    <% end %>
                  </tr>
                </tbody>
              </table>
            </div>
          </.form>

          <%!-- Clamped here rather than in the query: the pager's links are all
          built off it, so a page past the last would otherwise offer two more
          of them and draw `98` as though it were a page. A list read without
          a count has no last page to clamp to. --%>
          <.footer
            meta={@data}
            params={@params}
            path_for_page={@path_for_page}
            current_page={current_page(@params.page, pages_count(@data))}
            pages_count={pages_count(@data)}
          />
        </div>
      </div>
      <.export_modal
        :if={AshQuick.Config.exports_enabled?()}
        export_data={@export_data}
        export_format={@export_format}
        flash={assigns[:flash] || %{}}
      />
    </section>
    """
  end

  # What a row's checkbox is called: the record's display label, so a screen
  # reader moving down the column hears which record each box selects rather
  # than "Select row" over and over. The list query loads the label for this
  # (`AshQuick.LiveView.ListRead.list_query/3`). A label that names nothing —
  # blank, refused by a field policy, or `sensitive?` and so read as the same
  # mark on every row — falls back to the id, which still tells two boxes
  # apart.
  defp row_checkbox_label(%resource{} = row) do
    gettext("Select %{record}", record: row_name(resource, row))
  end

  defp row_name(resource, row) do
    label =
      if AshQuick.Info.sensitive?(resource, AshQuick.Info.display_label(resource)),
        do: nil,
        else: AshQuick.Info.display_value(row)

    if label in [nil, ""], do: to_string(Map.get(row, :id)), else: label
  end

  # The rows in the order they were drawn, each record still read back as
  # `{:row, record}` and each one that was not as `{:gone, %{id: id}}`: a
  # live refetch never moves a row, so what the reader was about to click is
  # still where it was. See `AshQuick.LiveView.ListRows`.
  defp screen_rows(results, nil, _gone), do: Enum.map(results, &{:row, &1})

  defp screen_rows(results, order, gone) do
    by_id = Map.new(results, &{&1.id, &1})

    for id <- order,
        slot =
          if(MapSet.member?(gone, id),
            do: {:gone, %{id: id}},
            else: by_id[id] && {:row, by_id[id]}
          ),
        do: slot
  end

  # A cell's own menu, offering to filter the list by what the cell holds:
  # see `AshQuick.LiveView.CellFilter`. Its button shows while the pointer
  # is over the cell, or once the cell is tapped or focused, so a list reads
  # as it did until a reader reaches for one; it sits over the cell's end
  # rather than beside it, so no column widens for it.
  #
  # Its entries are drawn only for the cell whose menu was last opened, as a
  # row's actions are (`record_actions/1`): a page of cells each holding a
  # menu would be several times the page, and every cell's text would read
  # its menu's words. Each entry sends only the record, the column and which
  # entry it is: the value is read back on the server, off the record the
  # page holds.
  attr(:record, :map, required: true)
  attr(:field, QuickField, required: true)
  attr(:column_filter, :map, required: true, doc: "the column's entry of `@cell_filters`")
  attr(:cell_menu, :map, default: nil)
  attr(:toward_start, :boolean, default: false)
  attr(:scope, :any, default: nil)

  defp cell_filter_menu(assigns) do
    %{filter_field: filter_field, emptiness?: emptiness?} = assigns.column_filter

    assigns =
      assign(assigns,
        id: to_string(assigns.record.id),
        column: QuickField.data_field(assigns.field),
        filter_field: filter_field,
        # Asked as the menu's events ask it (`CellFilterMenu`), so a cell
        # offers a menu only where opening it has an entry.
        offered?:
          CellFilter.choices(
            filter_field,
            QuickField.resolve_value(assigns.record, assigns.field.path),
            AshQuick.Scope.timezone(assigns.scope),
            emptiness?: emptiness?
          ) != []
      )

    ~H"""
    <div
      :if={@offered?}
      class="absolute inset-y-0 end-0 flex items-center pe-1"
      data-cell-filter={@column}
    >
      <%!-- Opened from a column of the table's first half toward the line's
      end, and from one of its second half toward its start, so it stays
      inside the table, which cuts off what passes its edge. --%>
      <Menu.menu
        id={"#{@id}-cell-filter-#{@column}"}
        class={@toward_start && "dropdown-end"}
        trigger_class="btn btn-xs btn-square bg-base-100 shadow-sm opacity-0 group-hover/cell:opacity-100 group-focus-within/cell:opacity-100 focus:opacity-100"
        content_class="menu menu-sm w-max max-w-72 p-2"
        label={gettext("Filter by this cell")}
        title={gettext("Filter by this cell")}
        on_open={JS.push("cell_filter_open", value: %{id: @id, column: @column})}
      >
        <:trigger><.icon name="hero-funnel-mini" class="w-3.5 h-3.5" /></:trigger>
        <%= case @cell_menu do %>
          <% %{id: id, column: column, choices: choices} when id == @id and column == @column -> %>
            <li :for={{choice, i} <- Enum.with_index(choices)} role="none">
              <button
                type="button"
                role="menuitem"
                tabindex="-1"
                class="whitespace-nowrap"
                data-cell-filter-choice={choice.operator}
                phx-click={JS.push("cell_filter", value: %{id: @id, column: @column, choice: i})}
              >
                <.icon name={choice_icon(choice)} class="w-4 h-4 shrink-0 opacity-70" />
                <span class="min-w-0 truncate">
                  {CellFilter.label(choice)}
                  <.choice_value choice={choice} filter_field={@filter_field} scope={@scope} />
                </span>
              </button>
            </li>
          <% _ -> %>
            <li class="menu-disabled" role="none">
              <span role="menuitem" aria-disabled="true" aria-label={gettext("Loading…")}>
                <span class="loading loading-spinner loading-xs" aria-hidden="true"></span>
              </span>
            </li>
        <% end %>
      </Menu.menu>
    </div>
    """
  end

  defp choice_icon(%CellFilter.Choice{kind: :out}), do: "hero-minus-circle"
  defp choice_icon(%CellFilter.Choice{}), do: "hero-plus-circle"

  # An item reads as its column shows one, a map's value as written; the
  # other entries name the cell's own value, which the reader is looking at.
  defp choice_value(%{choice: %CellFilter.Choice{kind: :item}} = assigns) do
    ~H"""
    <span class="font-semibold">
      <.field_value
        value={@choice.shown}
        path={[]}
        ash_field={@filter_field.field}
        resource={@filter_field.resource}
        scope={@scope}
      />
    </span>
    """
  end

  defp choice_value(%{choice: %CellFilter.Choice{kind: :pair}} = assigns) do
    ~H"""
    <span class="font-semibold" dir="auto">{CellFilter.shown_text(@choice.shown)}</span>
    """
  end

  defp choice_value(assigns), do: ~H""

  # The header's link leads to the next sort `URLParams.cycle_sort/2` gives the
  # column; its arrow says which way the list is sorted by it now, if at all.
  attr(:field, :map, required: true)
  attr(:params, :map, required: true)
  attr(:path, :string, required: true)

  defp sort_header(assigns) do
    assigns =
      assign(assigns,
        column: QuickField.data_field(assigns.field),
        direction: sort_direction(assigns.params, QuickField.data_field(assigns.field))
      )

    ~H"""
    <.link
      patch={URLParams.full_path(@path, URLParams.cycle_sort(@params, @column))}
      class="group inline-flex items-center gap-1 hover:text-base-content"
      data-sort={@column}
    >
      {Labels.field(@field)}
      <.icon :if={@direction == :asc} name="hero-chevron-up-mini" class="w-4 h-4" />
      <.icon :if={@direction == :desc} name="hero-chevron-down-mini" class="w-4 h-4" />
      <.icon
        :if={@direction == nil}
        name="hero-chevron-up-down-mini"
        class="w-4 h-4 opacity-30 group-hover:opacity-70"
      />
    </.link>
    """
  end

  defp sort_direction(%URLParams{sort: {column, direction}}, column), do: direction
  defp sort_direction(_params, _column), do: nil

  defp aria_sort(params, column) do
    case sort_direction(params, column) do
      :asc -> "ascending"
      :desc -> "descending"
      nil -> nil
    end
  end

  # Opens the filter modal, and counts the rows the list is filtered by, so a
  # filtered list never passes for the whole one, even with the chips scrolled
  # away.
  attr(:params, :map, required: true)
  attr(:path, :string, required: true)

  defp filter_button(assigns) do
    assigns =
      assign(
        assigns,
        :count,
        case assigns.params.custom_filter do
          %CustomFilter{} = filter -> filter |> CustomFilter.applied_leaves() |> length()
          nil -> 0
        end
      )

    ~H"""
    <.link
      patch={URLParams.full_path(@path, @params |> URLParams.toggle_show_custom_filter())}
      class="btn btn-ghost btn-sm btn-square indicator"
      title={gettext("Advanced filters")}
    >
      <.icon name="hero-adjustments-horizontal" class="w-5 h-5" />
      <%!-- Text inside the link outranks its `title` as its name, so the
      count alone would name it; this keeps "Advanced filters" first. --%>
      <span :if={@count > 0} class="sr-only">{gettext("Advanced filters")}</span>
      <span
        :if={@count > 0}
        id="ash-quick-filter-count"
        class="indicator-item badge badge-primary badge-xs"
      >
        <span aria-hidden="true">{@count}</span>
        <span class="sr-only">
          {ngettext("%{count} filter applied", "%{count} filters applied", @count)}
        </span>
      </span>
    </.link>
    """
  end

  # The shared modal: only its ✕ or Cancel closes it, and not while Apply
  # submits, when the ✕'s patch (made from the params before the filter)
  # would race the one Apply makes and could undo it.
  #
  # The close path is built inline, not assigned: an assign here is marked
  # changed on every render, and the filter form, handed it again, would go
  # back to the URL's filter and drop what was typed, as a flash dismissed
  # in the modal re-renders it.
  #
  # `held_filter` is one the list read without, as too slow to read with,
  # which the form opens holding to be narrowed.
  defp custom_filter_modal(assigns) do
    ~H"""
    <ActionModal.action_modal
      id="ash-quick-filter-modal"
      class="w-full max-w-2xl lg:max-w-4xl"
      close={URLParams.full_path(@path, URLParams.toggle_show_custom_filter(@params))}
      flash={@flash}
    >
      <:title>{gettext("Custom Filter")}</:title>
      <.live_component
        id="filter_form"
        module={AshQuick.LiveView.Components.FilterForm}
        resource={@resource}
        action={@action}
        filterable={@filterable}
        scope={@scope}
        custom_filter={@params.custom_filter || @held_filter}
        labels={FilterChips.column_labels(@columns)}
        close={URLParams.full_path(@path, URLParams.toggle_show_custom_filter(@params))}
      />
    </ActionModal.action_modal>
    """
  end

  defp render_field(%{field: %QuickField{widget: widget, path: path}, record: record} = assigns)
       when is_function(widget) do
    assigns = assigns |> assign(:value, QuickField.resolve_value(record, path))

    # A widget is written for the field's own type, so it is never handed the
    # mark Ash leaves in a field a policy hides: `field_value/1` renders that.
    case assigns.value do
      %Ash.ForbiddenField{} -> ~H"<.field_value value={@value} path={[]} scope={@scope} />"
      _ -> widget.(assigns)
    end
  end

  defp render_field(%{field: %QuickField{path: path}, record: record} = assigns) do
    assigns = assigns |> assign(:value, record) |> assign(:path, path)

    ~H"""
    <span class="relative">
      <.field_value value={@value} path={@path} scope={@scope} linker={@linker} />
    </span>
    """
  end

  # The menu resolves its own contents when it is opened, and only the open row's
  # are held in the assigns. Every entry costs an `Ash.can?` — a changeset build
  # plus a policy pass — so answering for every row up front made render time
  # scale with rows × actions, which is what a raised `?limit=` was really
  # paying for. See `ListUtils` "row_actions_open".
  #
  # Only the button opens the menu (`Menu`), so its click is the one moment
  # to ask. A click that closes it asks again, which costs one more round trip
  # on one row.
  defp record_actions(assigns) do
    ~H"""
    <Menu.menu
      id={"#{@record.id}-row-actions-dropdown"}
      class="dropdown-end"
      trigger_class="btn btn-ghost btn-xs btn-square"
      content_class="menu w-44 p-2"
      label={gettext("Row actions")}
      on_open={JS.push("row_actions_open", value: %{id: @record.id})}
    >
      <:trigger>
        <svg
          class="w-5 h-5"
          aria-hidden="true"
          fill="currentColor"
          viewbox="0 0 20 20"
          xmlns="http://www.w3.org/2000/svg"
        >
          <path d="M6 10a2 2 0 11-4 0 2 2 0 014 0zM12 10a2 2 0 11-4 0 2 2 0 014 0zM16 12a2 2 0 100-4 2 2 0 000 4z" />
        </svg>
      </:trigger>
      <.row_action_items record={@record} row_actions={@row_actions} />
    </Menu.menu>
    """
  end

  # Anything other than "this row, resolved" reads as pending: a row whose menu
  # has never been opened and one that has been superseded by another row's are
  # the same state, and the answer is one round trip away in both.
  defp row_action_items(%{record: %{id: id}, row_actions: %{id: id, actions: [_ | _]}} = assigns) do
    ~H"""
    <li :for={action <- @row_actions.actions} role="none">
      <.row_action record={@record} action={action} />
    </li>
    """
  end

  defp row_action_items(%{record: %{id: id}, row_actions: %{id: id, actions: []}} = assigns) do
    ~H"""
    <li class="menu-disabled" role="none">
      <span role="menuitem" aria-disabled="true">{gettext("No actions available")}</span>
    </li>
    """
  end

  defp row_action_items(assigns) do
    ~H"""
    <li class="menu-disabled" role="none">
      <span role="menuitem" aria-disabled="true">
        <span class="loading loading-spinner loading-xs" aria-hidden="true"></span> {gettext(
          "Loading…"
        )}
      </span>
    </li>
    """
  end

  defp row_action(assigns) do
    ~H"""
    <.link
      id={"#{@record.id}-action-#{@action.name}"}
      role="menuitem"
      tabindex="-1"
      phx-click={JS.push("row_action_click", value: %{id: @record.id, action_name: @action.name})}
    >
      {Labels.name(@action.name, @record.__struct__)}
    </.link>
    """
  end

  defp search_form(assigns) do
    ~H"""
    <.form for={%{}} id="search-form" phx-change="search" class="flex items-center">
      <label for="simple-search" class="sr-only">{gettext("Search")}</label>
      <label class="input input-sm flex items-center gap-2 w-full">
        <.icon name="hero-magnifying-glass" class="w-4 h-4 opacity-50" />
        <input
          type="text"
          id="simple-search"
          name="search"
          class="grow border-0 bg-transparent focus:ring-0 p-0 text-sm"
          placeholder={gettext("Search")}
          phx-debounce={120}
          value={@params.search}
        />
      </label>
    </.form>
    """
  end

  # The create page reaches only a public `:create` (see `reachable?/2` in
  # QuickView), so a private one gets no button: it would open a page that
  # refuses it.
  defp create_offered?(resource, scope) do
    Utils.public_action?(resource, :create) and
      AshQuick.can?({resource, :create}, scope, :ash_quick_list)
  end

  defp new_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@new_click && @new_click.()}
      class="btn btn-primary btn-sm"
    >
      <.icon name="hero-plus" class="h-4 w-4" />
      {Labels.translate(@new_action_label) || gettext("Create")}
    </button>
    """
  end

  # The list's Export, Actions and Filter menus sit at the end of the line
  # from `sm` up, and open from there toward its start. On a phone they sit
  # at its start instead, so the first of them opens toward the end: it is
  # wider than its button, and opening toward the start would run it past
  # the screen's edge.
  defp toolbar_menu, do: "dropdown-end max-sm:first:dropdown-start"

  defp export_menu(assigns) do
    ~H"""
    <Menu.menu id="export-menu" class={toolbar_menu()} content_class="menu w-28 p-2">
      <:trigger>
        <.icon name="hero-chevron-down" class="w-4 h-4" /> {gettext("Export")}
      </:trigger>
      <li role="none">
        <.link
          role="menuitem"
          tabindex="-1"
          phx-click="export"
          phx-value-format="xlsx"
          class="phx-click-loading:opacity-75"
        >
          Excel
        </.link>
      </li>
      <li role="none">
        <.link
          role="menuitem"
          tabindex="-1"
          phx-click="export"
          phx-value-format="csv"
          class="phx-click-loading:opacity-75"
        >
          CSV
        </.link>
      </li>
    </Menu.menu>
    """
  end

  defp too_many_rows_max({:error, {:too_many_rows, max}}), do: max

  defp export_modal(assigns) do
    ~H"""
    <ActionModal.action_modal
      :if={@export_data && @export_data.failed != {:exit, {:shutdown, :cancel}}}
      id="ash-quick-export-modal"
      close={JS.push("close-export-modal")}
      flash={@flash}
    >
      <:title>{gettext("Export")}</:title>
      <div class="flex flex-col items-center justify-center py-8">
        <div :if={@export_data.loading} class="flex flex-col items-center gap-3">
          <span class="loading loading-spinner loading-lg text-primary"></span>
          <span class="text-base-content/70">{gettext("Generating Data ...")}</span>
        </div>

        <div :if={@export_data.ok? && @export_data.result} class="flex flex-col items-center gap-4">
          <p class="text-success font-medium">{gettext("Data exported successfully!")}</p>
          <.link
            href={@export_data.result.url}
            target="_blank"
            class="btn btn-primary"
          >
            <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> {gettext("Download")}
          </.link>
        </div>

        <div
          :if={match?({:error, {:too_many_rows, _max}}, @export_data.failed)}
          class="flex flex-col items-center gap-2 text-center"
        >
          <div class="flex items-center gap-2 text-error">
            <.icon name="hero-exclamation-circle" class="w-6 h-6" />
            <p>{gettext("Too many rows to export")}</p>
          </div>
          <p>
            {gettext(
              "An export holds up to %{max} rows. Search or filter the list, then export again.",
              max: too_many_rows_max(@export_data.failed)
            )}
          </p>
        </div>

        <div
          :if={@export_data.failed && !match?({:error, {:too_many_rows, _max}}, @export_data.failed)}
          class="flex flex-col items-center gap-4"
        >
          <div class="flex items-center gap-2 text-error">
            <.icon name="hero-exclamation-circle" class="w-6 h-6" />
            <p>{gettext("Failed to export")}</p>
          </div>
          <%!-- Runs the failed export again. The rows come from the page's
          selection, which the modal sits over, so only the format is carried. --%>
          <button phx-click="export" phx-value-format={@export_format} class="btn btn-primary">
            <.icon name="hero-arrow-path" class="w-4 h-4" /> {gettext("Retry")}
          </button>
        </div>
      </div>
    </ActionModal.action_modal>
    """
  end

  defp actions_menu(assigns) do
    ~H"""
    <Menu.menu
      :if={
        (@filtered_actions && not Enum.empty?(@filtered_actions) && not @action_running) and
          @selected_rows != %{}
      }
      id="bulk-actions-menu"
      class={toolbar_menu()}
      content_class="menu w-44 p-2"
    >
      <:trigger>
        <.icon name="hero-chevron-down" class="w-4 h-4" /> {gettext("Actions")}
      </:trigger>
      <li :for={action <- @filtered_actions} role="none">
        <.link
          :if={action[:func]}
          role="menuitem"
          tabindex="-1"
          phx-click={action.func}
          class="phx-click-loading:opacity-75"
        >
          {action.title}
        </.link>
        <.link
          :if={action[:link]}
          role="menuitem"
          tabindex="-1"
          navigate={action.link}
          target="_blank"
        >
          {action.title}
        </.link>
      </li>
    </Menu.menu>
    """
  end

  defp filters_menu(assigns) do
    ~H"""
    <Menu.menu
      :if={@filters && Enum.count(@filters) > 0}
      id="filters-menu"
      kind={:panel}
      class={toolbar_menu()}
      content_class="w-48 p-3"
    >
      <:trigger>
        <.icon name="hero-funnel" class="w-4 h-4" /> {gettext("Filter")}
        <.icon name="hero-chevron-down" class="w-4 h-4" />
      </:trigger>
      <h6 class="mb-3 text-sm font-medium">
        {gettext("Select filters")}
      </h6>
      <ul class="space-y-2 text-sm">
        <li
          :for={%{"name" => filter_name, "label" => label} <- @filters}
          class="flex items-center cursor-pointer"
          phx-click={JS.push("toggle-filter", value: %{"name" => filter_name})}
        >
          <input
            id={"filter_#{filter_name}"}
            type="checkbox"
            checked={filter_name in @params.selected_filters}
            class="checkbox checkbox-sm"
          />
          <label
            for={"filter_#{filter_name}"}
            class="ms-2 text-sm font-medium cursor-pointer"
          >
            {Labels.translate(label)}
          </label>
        </li>
      </ul>
    </Menu.menu>
    """
  end

  defp present_actions(nil), do: nil
  defp present_actions(actions), do: Enum.filter(actions, & &1)

  # A lookup action has to paginate but need not count: one that declares
  # `countable false` reads back `count: nil`, and the list pages it by
  # `more?` instead, with no total and no last page.
  defp pages_count(%{count: count, limit: limit}) when is_integer(count), do: ceil(count / limit)
  defp pages_count(_page), do: nil

  defp current_page(page, nil), do: page
  defp current_page(page, pages_count), do: min(page, pages_count)

  # Whether the list holds more rows than `size`. Without a count, only the
  # rows up to this page's end are known, and `more?` says there is at least
  # one past it. An empty page past the end knows of none.
  defp more_rows_than?(%{count: count}, size) when is_integer(count), do: count > size
  defp more_rows_than?(%{results: []}, _size), do: false

  defp more_rows_than?(%{offset: offset, results: results, more?: more?}, size),
    do: more? or offset + length(results) > size

  # An empty page past the end of an uncounted list cannot tell how far back
  # the last row is, so it leads back to the first page rather than to another
  # empty one.
  defp previous_page(%{results: []}, _current_page), do: 1
  defp previous_page(_page, current_page), do: current_page - 1

  # Offered only when a pick would change the page: an action whose ceiling is
  # its default has one page size, and a list that fits on the smallest size
  # shows the same rows at every size. The smallest is never above the current
  # limit, so a list read past its default can still go back to it.
  defp page_size_form(assigns) do
    assigns = assign(assigns, :options, URLParams.page_size_options(assigns.params))

    ~H"""
    <.form
      :if={length(@options) > 1 and more_rows_than?(@meta, Enum.min(@options))}
      for={%{}}
      id="page-size-form"
      phx-change="page_size"
      class="flex items-center gap-2"
    >
      <label for="page-size" class="text-sm text-base-content/70">
        {gettext("Rows per page")}
      </label>
      <select id="page-size" name="limit" class="select select-sm w-auto">
        <option :for={size <- @options} value={size} selected={size == @params.limit}>
          {size}
        </option>
      </select>
    </.form>
    """
  end

  defp footer(assigns) do
    ~H"""
    <nav
      class="flex flex-col md:flex-row justify-between items-start md:items-center space-y-3 md:space-y-0 p-4"
      aria-label={gettext("Table navigation")}
    >
      <%!-- One message rather than text wrapped around two emphasised spans:
      a translator needs the whole sentence to order it, and the emphasis cannot
      survive being cut into fragments that no longer sit in that order. --%>
      <%!-- `min/2` clamps the arithmetic but nothing clamps the query, so a page
      past the last read "Showing 5-5 of 5" over an empty table. --%>
      <div class="flex flex-wrap items-center gap-3">
        <span class="text-sm text-base-content/70">
          {cond do
            is_nil(@meta.count) and @meta.results == [] and @meta.offset > 0 ->
              gettext("No results on this page")

            is_nil(@meta.count) ->
              gettext("Showing %{from}-%{to}",
                from: min(@meta.offset + 1, @meta.offset + length(@meta.results)),
                to: @meta.offset + length(@meta.results)
              )

            @meta.results == [] and @meta.count > 0 ->
              gettext("No results on this page, of %{count} in total", count: @meta.count)

            true ->
              gettext("Showing %{from}-%{to} of %{count}",
                from: min(@meta.offset + 1, @meta.count),
                to: min(@meta.offset + @meta.limit, @meta.count),
                count: @meta.count
              )
          end}
        </span>
        <.page_size_form meta={@meta} params={@params} />
      </div>
      <%!-- Without a count there is no last page to link to: the pager steps
      one page either way, and forward only while Ash says there is more. --%>
      <div :if={is_nil(@pages_count) and (@current_page > 1 or @meta.more?)} class="join">
        <.link
          :if={@current_page > 1}
          patch={@path_for_page.(previous_page(@meta, @current_page))}
          aria-label={gettext("Previous page")}
          class="join-item btn btn-sm"
        >
          <.icon name="hero-chevron-left" class="w-4 h-4 rtl:rotate-180" />
        </.link>
        <.link
          patch={@path_for_page.(@current_page)}
          aria-current="page"
          class="join-item btn btn-sm btn-active"
        >
          {@current_page}
        </.link>
        <.link
          :if={@meta.more?}
          patch={@path_for_page.(@current_page + 1)}
          aria-label={gettext("Next page")}
          class="join-item btn btn-sm"
        >
          <.icon name="hero-chevron-right" class="w-4 h-4 rtl:rotate-180" />
        </.link>
      </div>
      <div :if={@pages_count && @meta.count > @meta.limit} class="join">
        <.link
          :if={@current_page > 1}
          patch={@path_for_page.(@current_page - 1)}
          aria-label={gettext("Previous page")}
          class="join-item btn btn-sm"
        >
          <.icon name="hero-chevron-left" class="w-4 h-4 rtl:rotate-180" />
        </.link>
        <.link
          patch={@path_for_page.(1)}
          aria-current={@current_page == 1 && "page"}
          class={[
            "join-item btn btn-sm",
            @current_page == 1 && "btn-active"
          ]}
        >
          1
        </.link>
        <span
          :if={@current_page > 3}
          class="join-item btn btn-sm btn-disabled"
        >
          ...
        </span>
        <.link
          :if={@current_page > 2}
          patch={@path_for_page.(@current_page - 1)}
          class="join-item btn btn-sm"
        >
          {@current_page - 1}
        </.link>
        <.link
          :if={@current_page > 1 && @current_page < @pages_count}
          patch={@path_for_page.(@current_page)}
          aria-current="page"
          class="join-item btn btn-sm btn-active"
        >
          {@current_page}
        </.link>

        <.link
          :for={
            page_num <-
              Enum.take((@current_page + 1)..(@pages_count - 1)//1, max(4 - @current_page, 1))
          }
          :if={@current_page < @pages_count - 1}
          patch={@path_for_page.(page_num)}
          class="join-item btn btn-sm"
        >
          {page_num}
        </.link>
        <span
          :if={@current_page < @pages_count - 2}
          class="join-item btn btn-sm btn-disabled"
        >
          ...
        </span>
        <.link
          patch={@path_for_page.(@pages_count)}
          aria-current={@current_page == @pages_count && "page"}
          class={[
            "join-item btn btn-sm",
            @current_page == @pages_count && "btn-active"
          ]}
        >
          {@pages_count}
        </.link>
        <.link
          :if={@current_page < @pages_count}
          patch={@path_for_page.(@current_page + 1)}
          aria-label={gettext("Next page")}
          class="join-item btn btn-sm"
        >
          <.icon name="hero-chevron-right" class="w-4 h-4 rtl:rotate-180" />
        </.link>
      </div>
    </nav>
    """
  end
end
