defmodule AshQuick.LiveView.Components.NavGrid do
  @moduledoc """
  The nav registry rendered as a grid of tiles: one per group the viewer can
  reach, linking to the first path in it they are allowed to navigate to.

  A group with nothing reachable in it has no tile at all, so the grid is a
  picture of what this user can do rather than of what the application has.

  Placed by the host, wherever its apps menu or home page is: the layout
  `mix igniter.install ash_quick` generates puts it in a dropdown of the top
  bar. It sizes itself off its own box, so it fits a dropdown, a drawer and a
  full page alike.

      <.nav_grid scope={@scope} />
  """
  use Phoenix.Component

  import AshQuick.Components

  alias AshQuick.Nav

  attr :scope, :any,
    required: true,
    doc: "The page's scope. Only the groups its access control grants are drawn."

  @doc "The nav's groups the scope can reach, as tiles."
  def nav_grid(assigns) do
    tiles =
      assigns.scope
      |> Nav.Info.sections()
      |> Enum.filter(& &1.group)
      |> Enum.map(&%{group: &1.group, path: hd(&1.entries).path})

    assigns = assign(assigns, :tiles, tiles)

    ~H"""
    <%!-- The grid renders at three very different widths (home page, navbar
    dropdown, mobile drawer), so it sizes off its own box, not the viewport.
    22rem clears the 382px dropdown and stays above the ~343px phone home. --%>
    <div class="@container">
      <div class="grid grid-cols-2 @min-[22rem]:grid-cols-3 @xl:grid-cols-4 gap-3 @min-[22rem]:gap-4 p-3 @min-[22rem]:p-4 bg-base-200 rounded-xl shadow-lg">
        <.link
          :for={tile <- @tiles}
          navigate={tile.path}
          class="block px-1 py-2 @min-[22rem]:py-4 text-center rounded-lg hover:bg-base-300/70 group"
        >
          <.nav_icon
            icon={tile.group.icon}
            class="mx-auto mb-1 w-6/12 @min-[22rem]:w-5/12 max-w-32 h-auto aspect-square text-base-content/40 group-hover:text-base-content/60"
          />
          <%!-- A one-word label can't wrap, so it would spill past the tile:
          thin side padding fits it, and hyphenation catches what still won't. --%>
          <div class="text-xs @min-[22rem]:text-sm break-words hyphens-auto">{tile.group.label}</div>
        </.link>
      </div>
    </div>
    """
  end
end
