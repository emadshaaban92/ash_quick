defmodule AshQuick.LiveView.Components.NavGrid do
  @moduledoc false
  # The nav registry rendered as a grid of tiles: one per group the viewer can
  # reach, linking to the first path in it they are allowed to navigate to.
  #
  # A group with nothing reachable in it has no tile at all, so the grid is a
  # picture of what this user can do rather than of what the application has.
  use Phoenix.Component

  import AshQuick.Components

  alias AshQuick.Nav

  attr :scope, :any, required: true

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
          class="block p-2 @min-[22rem]:p-4 text-center rounded-lg hover:bg-base-300/70 group"
        >
          <.nav_icon
            icon={tile.group.icon}
            class="mx-auto mb-1 w-6/12 @min-[22rem]:w-5/12 max-w-32 h-auto aspect-square text-base-content/40 group-hover:text-base-content/60"
          />
          <div class="text-xs @min-[22rem]:text-sm">{tile.group.label}</div>
        </.link>
      </div>
    </div>
    """
  end
end
