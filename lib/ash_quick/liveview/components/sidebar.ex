defmodule AshQuick.LiveView.Components.Sidebar do
  @moduledoc false
  # The nav registry rendered as a sidebar: one heading per group the viewer
  # can reach, the entries under it, and the page they are on marked.
  #
  # It knows nothing about resources or domains — a path is a path, so a scan
  # page and a dashboard sit beside a QuickView, and a group spans as many
  # domains as it likes. `AshQuick.LiveView.Components.NavGrid` renders the
  # same sections as tiles.
  #
  # A group of one path is a tile in the grid and nothing in a sidebar: the
  # heading says what its single link already says. It is dropped on what the
  # group *declares*, never on what survives filtering — a role who can reach
  # one page of Settings still needs to be told it is Settings, and a sidebar
  # whose shape moves with the viewer is harder to learn, not easier.
  #
  # It is rendered by the host's layout, not by a view, because every page a
  # user can reach needs the same nav — a scan screen is not less navigable
  # than a list. It therefore asks only for the path being served, and marks
  # the entry that path falls under by the prefix rule the whole registry
  # matches on, so `/products/123` marks Products without knowing what a
  # QuickView is.
  use Phoenix.Component
  use Gettext, backend: AshQuick.Gettext

  import AshQuick.Components

  alias AshQuick.LiveView.URLParams
  alias AshQuick.Nav
  alias Phoenix.LiveView.JS

  attr :scope, :any, required: true
  attr :current_path, :string, required: true

  attr :params, :any,
    default: nil,
    doc: """
    The list params of the page being served, when it has any. The marked entry
    links back to itself carrying them, so returning to a list from one of its
    records keeps the filters. A page with no list state passes nothing.
    """

  def sidebar(assigns) do
    assigns =
      assigns
      |> assign(:sections, assigns.scope |> Nav.Info.sections() |> with_rules())
      |> assign(:list_params, list_params(assigns.params))

    ~H"""
    <button
      type="button"
      phx-click={toggle_sidebar()}
      class="lg:hidden fixed top-[4.5rem] sm:top-[5.25rem] start-3 z-50 btn btn-sm btn-ghost btn-square bg-base-100 shadow-sm border border-base-300 print:hidden"
      aria-label={gettext("Toggle sidebar")}
      id="sidebar-toggle"
    >
      <.icon name="hero-bars-3" class="w-5 h-5" />
    </button>
    <div
      id="sidebar-backdrop"
      phx-click={toggle_sidebar()}
      class="hidden fixed inset-0 z-30 bg-base-content/30 lg:hidden"
    />
    <%!-- Bounded by `bottom-0`, not `h-full`: height on a fixed element resolves
    against the viewport, so `h-full` under a `top-*` offset hangs that much of
    the scroll container below the fold, where its last entries cannot be
    scrolled to at all. --%>
    <%!-- The closed state is mobile-scoped so nothing has to outrank it at `lg`:
    `rtl:` compiles to a zero-specificity `:where()` and `lg:` to a media query,
    so a desktop `translate-x-0` ties with the RTL rule and loses on source
    order, hiding the sidebar exactly where it is meant to stay pinned. --%>
    <aside
      id="default-sidebar"
      class="fixed top-16 sm:top-20 bottom-0 start-0 z-40 w-64 transition-transform max-lg:-translate-x-full max-lg:rtl:translate-x-full"
      aria-label={gettext("Sidenav")}
    >
      <div class="overflow-y-auto py-5 px-3 h-full bg-base-100 border-e border-base-300">
        <ul class="menu w-full p-0 gap-1">
          <%= for {section, rule} <- @sections do %>
            <li :if={rule} class="mt-2 mb-1 border-t border-base-300" aria-hidden="true"></li>
            <li :if={heading?(section)} class="menu-title flex flex-row items-center gap-2">
              <.nav_icon icon={section.group.icon} class="w-4 h-4" />
              {section.group.label}
            </li>
            <li :for={entry <- section.entries}>
              <%!-- Patching keeps the list params, but only the view that owns
              them can answer one; every other page navigates to itself. --%>
              <.link
                :if={marked?(entry, @current_path) and @list_params}
                patch={URLParams.full_path(entry.path, @list_params)}
                class="bg-base-300 hover:bg-base-200"
              >
                <.nav_icon icon={entry.icon} class="w-6 h-6 text-base-content/60" />
                {entry.label}
              </.link>
              <.link
                :if={marked?(entry, @current_path) and is_nil(@list_params)}
                navigate={entry.path}
                class="bg-base-300 hover:bg-base-200"
              >
                <.nav_icon icon={entry.icon} class="w-6 h-6 text-base-content/60" />
                {entry.label}
              </.link>
              <.link
                :if={not marked?(entry, @current_path)}
                navigate={entry.path}
                phx-click={toggle_sidebar()}
              >
                <.nav_icon
                  icon={entry.icon}
                  class="w-6 h-6 text-base-content/60 transition duration-75 group-hover:text-base-content"
                />
                {entry.label}
              </.link>
            </li>
          <% end %>
        </ul>
      </div>
    </aside>
    """
  end

  # A section with no heading has nothing to set it off from the one above, so
  # the first of a run gets a rule. Consecutive headless sections read as one
  # list of standalone links and share it, and the next heading ends the run.
  defp with_rules(sections) do
    [nil | sections]
    |> Enum.zip(sections)
    |> Enum.map(fn {previous, section} -> {section, rule?(previous, section)} end)
  end

  defp rule?(nil, _section), do: false
  defp rule?(previous, section), do: not heading?(section) and heading?(previous)

  defp heading?(%{group: nil}), do: false
  defp heading?(%{group: group}), do: length(group.paths) > 1

  # The rule the registry matches everywhere else: an entry owns the paths under
  # it, so a record marks the list it belongs to and `/scan/history` marks Scan.
  defp marked?(_entry, nil), do: false
  defp marked?(entry, current_path), do: Nav.Info.allowed?(current_path, [entry.path])

  # The layout hands over whatever the page called `params`, which is only list
  # state when the page is a QuickView list — a bulk importer has an assign of
  # that name and a shape of its own. Anything else marks its entry with a
  # plain link rather than a patch nothing can answer.
  defp list_params(%URLParams{} = params), do: URLParams.to_list_params(params)
  defp list_params(_params), do: nil

  defp toggle_sidebar do
    JS.toggle_class("hidden", to: "#sidebar-backdrop")
    |> JS.toggle_class("max-lg:-translate-x-full max-lg:rtl:translate-x-full",
      to: "#default-sidebar"
    )
    |> JS.toggle_class("translate-x-0", to: "#default-sidebar")
  end
end
