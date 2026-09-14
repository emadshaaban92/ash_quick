defmodule ExampleWeb.Layouts do
  @moduledoc """
  The two layouts every page is served through.

  The nav is rendered here rather than by a view, because every page a user can
  reach needs the same nav — `AshQuick.LiveView.Components.Sidebar` and
  `AshQuick.LiveView.Components.NavGrid` are two renderings of
  `ExampleWeb.Nav`, filtered through `ExampleWeb.AccessControl`. A QuickView
  opts out of the rail with `sidebar: false`.
  """
  use ExampleWeb, :html

  import AshQuick.LiveView.Components.ImpersonationBanner
  import AshQuick.LiveView.Components.NavGrid
  import AshQuick.LiveView.Components.Sidebar

  alias AshQuick.LiveView.Impersonation

  embed_templates "layouts/*"

  @doc """
  Whether this page is offered the nav rail.

  A signed-in user gets it unless the page said otherwise — `sidebar: false` on
  a QuickView, or the same assign set in a plain LiveView's `mount/3`. The home
  page opts out: it *is* the apps grid, so a rail beside it lists what the page
  already shows.
  """
  def nav?(assigns) do
    assigns[:current_path] != nil and
      assigns[:scope] != nil and
      assigns.scope.current_user != nil and
      assigns[:sidebar] != false
  end

  @doc "Shows the flash group with standard titles and content."
  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end
end
