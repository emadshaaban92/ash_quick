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
  alias AshQuick.LiveView.Components.FilterChips
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

  attr(:row_actions, :map,
    default: nil,
    doc: "`%{id: record_id, actions: [action]}` for the row whose menu was last opened"
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
    <section class="bg-base-200 p-3 sm:p-5">
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
              />

              <div class="flex items-center w-full space-x-2">
                <div class="flex-1">
                  <.search_form params={@params} />
                </div>
                <.filter_button params={@params} path={@path} />
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
            columns={@fields}
          />
          <.form for={%{}} id="table-form" phx-change="table-form-change">
            <div class="overflow-x-auto min-h-[20rem] lg:min-h-[30rem]">
              <table class="table table-sm text-base-content">
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
                    :for={row <- @data.results}
                    id={row.id}
                    :key={row.id}
                    class={[
                      @row_css_class && @row_css_class.(row),
                      AshQuick.Info.inactive?(row) && "opacity-50"
                    ]}
                  >
                    <td :if={@selected_rows} class="w-4">
                      <input
                        id={"select_row_#{row.id}"}
                        name={"#{row.id}"}
                        type="checkbox"
                        aria-label={gettext("Select row")}
                        checked={@selected_rows[row.id] == "on"}
                        class="checkbox checkbox-sm bg-base-300 text-base-content"
                      />
                    </td>
                    <td :for={field <- @fields}>
                      <.render_field field={field} record={row} scope={@scope} />
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
                  </tr>
                </tbody>
              </table>
            </div>
          </.form>

          <%!-- Clamped here rather than in the query: the pager's links are all
          built off it, so a page past the last would otherwise offer two more
          of them and draw `98` as though it were a page. --%>
          <.footer
            meta={@data}
            params={@params}
            path_for_page={@path_for_page}
            current_page={min(@params.page, pages_count(@data))}
            pages_count={pages_count(@data)}
          />
        </div>
      </div>
      <.export_modal :if={AshQuick.Config.exports_enabled?()} export_data={@export_data} />
    </section>
    """
  end

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
  defp custom_filter_modal(assigns) do
    assigns =
      assign(
        assigns,
        :close,
        URLParams.full_path(assigns.path, URLParams.toggle_show_custom_filter(assigns.params))
      )

    ~H"""
    <ActionModal.action_modal
      id="ash-quick-filter-modal"
      class="w-full max-w-2xl lg:max-w-4xl"
      close={@close}
    >
      <:title>{gettext("Custom Filter")}</:title>
      <.live_component
        id="filter_form"
        module={AshQuick.LiveView.Components.FilterForm}
        resource={@resource}
        action={@action}
        scope={@scope}
        custom_filter={@params.custom_filter}
        labels={FilterChips.column_labels(@columns)}
        close={@close}
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
      <.field_value value={@value} path={@path} scope={@scope} />
    </span>
    """
  end

  # The menu resolves its own contents when it is opened, and only the open row's
  # are held in the assigns. Every entry costs an `Ash.can?` — a changeset build
  # plus a policy pass — so answering for every row up front made render time
  # scale with rows × actions, which is what a raised `?limit=` was really
  # paying for. See `ListUtils` "row_actions_open".
  #
  # Both focus and click, because either can be the one that opens the menu: the
  # dropdown is the CSS variant, so a keyboard user who tabs to the trigger has it
  # open having never clicked, and a pointer user on a UA that doesn't focus a
  # `tabindex` div has clicked without focusing. Asking twice costs one more
  # round trip on one row; asking on the wrong one leaves the menu on its
  # placeholder for good.
  defp record_actions(assigns) do
    ~H"""
    <div id={"#{@record.id}-row-actions-dropdown"} class="dropdown dropdown-end">
      <div
        tabindex="0"
        role="button"
        class="btn btn-ghost btn-xs btn-square"
        phx-focus={JS.push("row_actions_open", value: %{id: @record.id})}
        phx-click={JS.push("row_actions_open", value: %{id: @record.id})}
      >
        <span class="sr-only">{gettext("Row actions")}</span>
        <svg
          class="w-5 h-5"
          aria-hidden="true"
          fill="currentColor"
          viewbox="0 0 20 20"
          xmlns="http://www.w3.org/2000/svg"
        >
          <path d="M6 10a2 2 0 11-4 0 2 2 0 014 0zM12 10a2 2 0 11-4 0 2 2 0 014 0zM16 12a2 2 0 100-4 2 2 0 000 4z" />
        </svg>
      </div>
      <ul
        tabindex="0"
        class="dropdown-content menu bg-base-300 rounded-box z-10 w-44 p-2 shadow-[0_2px_15px_rgba(0,0,0,0.3)] border border-base-content/10"
      >
        <.row_action_items record={@record} row_actions={@row_actions} />
      </ul>
    </div>
    """
  end

  # Anything other than "this row, resolved" reads as pending: a row whose menu
  # has never been opened and one that has been superseded by another row's are
  # the same state, and the answer is one round trip away in both.
  defp row_action_items(%{record: %{id: id}, row_actions: %{id: id, actions: [_ | _]}} = assigns) do
    ~H"""
    <li :for={action <- @row_actions.actions}>
      <.row_action record={@record} action={action} />
    </li>
    """
  end

  defp row_action_items(%{record: %{id: id}, row_actions: %{id: id, actions: []}} = assigns) do
    ~H"""
    <li class="menu-disabled"><span>{gettext("No actions available")}</span></li>
    """
  end

  defp row_action_items(assigns) do
    ~H"""
    <li class="menu-disabled">
      <span><span class="loading loading-spinner loading-xs"></span> {gettext("Loading…")}</span>
    </li>
    """
  end

  defp row_action(assigns) do
    ~H"""
    <.link
      id={"#{@record.id}-action-#{@action.name}"}
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

  defp export_menu(assigns) do
    ~H"""
    <div class="dropdown dropdown-end">
      <div tabindex="0" role="button" class="btn btn-outline btn-sm">
        <.icon name="hero-chevron-down" class="w-4 h-4" /> {gettext("Export")}
      </div>
      <ul
        tabindex="0"
        class="dropdown-content menu bg-base-300 rounded-box z-10 w-28 p-2 shadow-[0_2px_15px_rgba(0,0,0,0.3)] border border-base-content/10"
      >
        <li>
          <.link
            phx-click="export"
            phx-value-format="xlsx"
            class="phx-click-loading:opacity-75"
          >
            Excel
          </.link>
        </li>
        <li>
          <.link
            phx-click="export"
            phx-value-format="csv"
            class="phx-click-loading:opacity-75"
          >
            CSV
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  defp export_modal(assigns) do
    ~H"""
    <ActionModal.action_modal
      :if={@export_data && @export_data.failed != {:exit, {:shutdown, :cancel}}}
      id="ash-quick-export-modal"
      close={JS.push("close-export-modal")}
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

        <div :if={@export_data.failed} class="flex flex-col items-center gap-4">
          <div class="flex items-center gap-2 text-error">
            <.icon name="hero-exclamation-circle" class="w-6 h-6" />
            <p>{gettext("Failed to export")}</p>
          </div>
          <button phx-click="start-gen-report" class="btn btn-primary">
            <.icon name="hero-arrow-path" class="w-4 h-4" /> {gettext("Retry")}
          </button>
        </div>
      </div>
    </ActionModal.action_modal>
    """
  end

  defp actions_menu(assigns) do
    ~H"""
    <div
      :if={
        (@filtered_actions && not Enum.empty?(@filtered_actions) && not @action_running) and
          @selected_rows != %{}
      }
      class="dropdown dropdown-end"
    >
      <div tabindex="0" role="button" class="btn btn-outline btn-sm">
        <.icon name="hero-chevron-down" class="w-4 h-4" /> {gettext("Actions")}
      </div>
      <ul
        id="bulk-actions-menu"
        tabindex="0"
        class="dropdown-content menu bg-base-300 rounded-box z-10 w-44 p-2 shadow-[0_2px_15px_rgba(0,0,0,0.3)] border border-base-content/10"
      >
        <li :for={action <- @filtered_actions}>
          <.link
            :if={action[:func]}
            phx-click={action.func}
            class="phx-click-loading:opacity-75"
          >
            {action.title}
          </.link>
          <.link
            :if={action[:link]}
            navigate={action.link}
            target="_blank"
          >
            {action.title}
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  defp filters_menu(assigns) do
    ~H"""
    <div :if={@filters && Enum.count(@filters) > 0} class="dropdown dropdown-end">
      <div tabindex="0" role="button" class="btn btn-outline btn-sm">
        <.icon name="hero-funnel" class="w-4 h-4" /> {gettext("Filter")}
        <.icon name="hero-chevron-down" class="w-4 h-4" />
      </div>
      <div
        tabindex="0"
        class="dropdown-content bg-base-300 rounded-box z-10 w-48 p-3 shadow-[0_2px_15px_rgba(0,0,0,0.3)] border border-base-content/10"
      >
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
      </div>
    </div>
    """
  end

  defp present_actions(nil), do: nil
  defp present_actions(actions), do: Enum.filter(actions, & &1)

  defp pages_count(%{count: count, limit: limit}), do: ceil(count / limit)

  # Offered only when a pick would change the page: an action whose ceiling is
  # its default has one page size, and a list that fits on the smallest size
  # shows the same rows at every size. The smallest is never above the current
  # limit, so a list read past its default can still go back to it.
  defp page_size_form(assigns) do
    assigns = assign(assigns, :options, URLParams.page_size_options(assigns.params))

    ~H"""
    <.form
      :if={length(@options) > 1 and @meta.count > Enum.min(@options)}
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
          {if @meta.results == [] and @meta.count > 0 do
            gettext("No results on this page, of %{count} in total", count: @meta.count)
          else
            gettext("Showing %{from}-%{to} of %{count}",
              from: min(@meta.offset + 1, @meta.count),
              to: min(@meta.offset + @meta.limit, @meta.count),
              count: @meta.count
            )
          end}
        </span>
        <.page_size_form meta={@meta} params={@params} />
      </div>
      <div :if={@meta.count > @meta.limit} class="join">
        <.link
          :if={@current_page > 1}
          patch={@path_for_page.(@current_page - 1)}
          aria-label={gettext("Previous page")}
          class="join-item btn btn-sm"
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" />
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
          <.icon name="hero-chevron-right" class="w-4 h-4" />
        </.link>
      </div>
    </nav>
    """
  end
end
