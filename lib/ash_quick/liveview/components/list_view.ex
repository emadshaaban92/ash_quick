defmodule AshQuick.LiveView.Components.ListView do
  @moduledoc false
  use Phoenix.Component
  use Gettext, backend: AshQuick.Gettext
  import AshQuick.Components
  alias Phoenix.LiveView.JS

  import AshQuick.LiveView.Components.FieldValue
  import AshQuick.LiveView.Components.PrintModal

  alias AshQuick.LiveView.Utils
  alias AshQuick.LiveView.QuickField
  alias AshQuick.LiveView.URLParams

  attr(:id, :string, required: true)
  attr(:resource, :map, required: true)
  attr(:new_action_label, :string, default: nil)
  attr(:new_click, :any, default: nil, doc: "the function for handling phx-click on new button")
  attr(:fields, :list, required: true)
  attr(:rows, :list, required: true)
  attr(:row_id, :any, default: nil, doc: "the function for generating the row id")

  attr(:row_css_class, :any,
    default: nil,
    doc: "the function for adding extra css classes on each row"
  )

  attr(:row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"
  )

  attr(:scope, :map, required: true)
  attr(:params, :map, default: nil)
  attr(:meta, :map, default: nil)

  attr(:path_for_page, :any, default: nil, doc: "the function for generating pagination paths")

  attr(:actions, :any, default: nil)
  attr(:print_actions, :list, default: [])
  attr(:filters, :map, default: nil)
  attr(:selected_rows, :map, default: nil)
  attr(:action_running, :boolean, default: false)

  attr(:row_actions, :map,
    default: nil,
    doc: "`%{id: record_id, actions: [action]}` for the row whose menu was last opened"
  )

  def list_view(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    params = assigns[:params]
    meta = assigns[:data]
    actions = assigns[:actions]

    assigns =
      assigns
      |> assign(:current_page, params.page)
      |> assign(:pages_count, Float.ceil(meta.count / meta.limit) |> trunc())
      |> assign(:filtered_actions, actions && actions |> Enum.filter(& &1))
      |> assign(:meta, meta)
      |> assign(:rows, assigns.data.results)

    ~H"""
    <section class="bg-base-200 p-3 sm:p-5">
      <div class="mx-auto max-w-full">
        <div class="card bg-base-100 shadow-md overflow-hidden">
          <div class="flex flex-col lg:flex-row items-center justify-between space-y-3 lg:space-y-0 lg:space-x-4 p-4">
            <div class="w-full lg:w-1/2 flex flex-col sm:flex-row space-y-2 sm:space-y-0 items-stretch sm:items-center sm:space-x-3">
              <.custom_filter_modal
                :if={@params.show_custom_filter}
                resource={@resource}
                params={@params}
                path={@path}
              />

              <div class="flex items-center w-full space-x-2">
                <div class="flex-1">
                  <.search_form params={@params} />
                </div>
                <.link
                  patch={URLParams.full_path(@path, @params |> URLParams.toggle_show_custom_filter())}
                  class="btn btn-ghost btn-sm btn-square"
                  title={gettext("Advanced filters")}
                >
                  <.icon name="hero-adjustments-horizontal" class="w-5 h-5" />
                </.link>
              </div>
            </div>
            <div class="w-full lg:w-auto flex flex-col sm:flex-row space-y-2 sm:space-y-0 items-stretch sm:items-center justify-end sm:space-x-3 shrink-0">
              <.new_button
                :if={
                  :create in @routed_shapes and
                    AshQuick.can?({@resource, :create}, @scope, :ash_quick_list)
                }
                new_click={@new_click}
                new_action_label={@new_action_label}
              />
              <div class="flex items-center space-x-3 w-full sm:w-auto">
                <.export_menu :if={AshQuick.Config.exports_enabled?()} />
                <.print_menu
                  :if={AshQuick.Config.print_enabled?() and @print_actions != []}
                  print_actions={@print_actions}
                  selected_rows={@selected_rows}
                />
                <.actions_menu
                  filtered_actions={@filtered_actions}
                  action_running={@action_running}
                  selected_rows={@selected_rows}
                />
                <.filters_menu filters={@filters} params={@params} />
              </div>
            </div>
          </div>
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
                    <th :for={field <- @fields}>
                      {field.label}
                    </th>
                    <th>
                      <span class="sr-only">{gettext("Actions")}</span>
                    </th>
                  </tr>
                </thead>
                <tbody id={@id}>
                  <tr
                    :for={row <- @rows}
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
                      <.render_field field={field} record={row} />
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
            meta={@meta}
            path_for_page={@path_for_page}
            current_page={min(@current_page, @pages_count)}
            pages_count={@pages_count}
          />
        </div>
      </div>
      <.export_modal :if={AshQuick.Config.exports_enabled?()} export_data={@export_data} />
      <.print_modal :if={AshQuick.Config.print_enabled?()} print_data={@print_data} />
    </section>
    """
  end

  defp custom_filter_modal(assigns) do
    ~H"""
    <dialog class="modal modal-open">
      <div class="modal-box w-full max-w-2xl lg:max-w-4xl">
        <div class="flex justify-between items-center mb-4">
          <h3 class="text-lg font-semibold">
            {gettext("Custom Filter")}
          </h3>
          <.link
            patch={URLParams.full_path(@path, @params |> URLParams.toggle_show_custom_filter())}
            class="btn btn-sm btn-circle btn-ghost"
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </.link>
        </div>
        <.live_component
          :if={@params.show_custom_filter}
          id="filter_form"
          module={AshQuick.LiveView.Components.FilterForm}
          resource={@resource}
          custom_filter={@params.custom_filter}
        />
      </div>
      <.link
        patch={URLParams.full_path(@path, @params |> URLParams.toggle_show_custom_filter())}
        class="modal-backdrop"
      >
        <span class="sr-only">{gettext("Close")}</span>
      </.link>
    </dialog>
    """
  end

  defp render_field(%{field: %QuickField{widget: widget, path: path}, record: record} = assigns)
       when is_function(widget) do
    assigns = assigns |> assign(:value, resolve_value(record, path))
    widget.(assigns)
  end

  defp render_field(%{field: %QuickField{path: path}, record: record} = assigns) do
    assigns = assigns |> assign(:value, record) |> assign(:path, path)

    ~H"""
    <span class="relative">
      <.field_value value={@value} path={@path} />
    </span>
    """
  end

  defp resolve_value(record, path) when is_atom(path), do: Map.get(record, path)

  defp resolve_value(record, [{relationship, nested}]) do
    record |> Map.get(relationship) |> resolve_value(nested)
  end

  defp resolve_value(nil, _path), do: nil

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
    data_confirm =
      assigns.record
      |> Ash.Resource.Info.action_inputs(assigns.action.name)
      |> Enum.to_list()
      |> case do
        [] -> gettext("Are you sure?")
        _ -> nil
      end

    assigns = assigns |> assign(data_confirm: data_confirm)

    ~H"""
    <.link
      id={"#{@record.id}-action-#{@action.name}"}
      phx-click={JS.push("row_action_click", value: %{id: @record.id, action_name: @action.name})}
      data-confirm={@data_confirm}
    >
      {Utils.humanize(@action.name)}
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

  defp new_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@new_click && @new_click.()}
      class="btn btn-primary btn-sm"
    >
      <.icon name="hero-plus" class="h-4 w-4" />
      {@new_action_label || gettext("Create")}
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
    <dialog
      :if={@export_data && @export_data.failed != {:exit, {:shutdown, :cancel}}}
      class="modal modal-open"
    >
      <div class="modal-box">
        <div class="flex justify-between items-center mb-4">
          <h3 class="text-lg font-semibold">{gettext("Export")}</h3>
          <.link phx-click="close-export-modal" class="btn btn-sm btn-circle btn-ghost">
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </.link>
        </div>
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
      </div>
      <div class="modal-backdrop">
        <button phx-click="close-export-modal">{gettext("close")}</button>
      </div>
    </dialog>
    """
  end

  defp print_menu(assigns) do
    ~H"""
    <div
      :if={@selected_rows != %{}}
      class="dropdown dropdown-end"
    >
      <div tabindex="0" role="button" class="btn btn-outline btn-sm">
        <.icon name="hero-printer" class="w-4 h-4" /> {gettext("Print")}
      </div>
      <ul
        tabindex="0"
        class="dropdown-content menu bg-base-300 rounded-box z-10 w-44 p-2 shadow-[0_2px_15px_rgba(0,0,0,0.3)] border border-base-content/10"
      >
        <li :for={action <- @print_actions}>
          <.link
            phx-click={action.func}
            class="phx-click-loading:opacity-75"
          >
            {action.title}
          </.link>
        </li>
      </ul>
    </div>
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
              {label}
            </label>
          </li>
        </ul>
      </div>
    </div>
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
