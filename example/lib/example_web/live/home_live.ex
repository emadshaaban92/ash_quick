defmodule ExampleWeb.HomeLive do
  @moduledoc """
  The apps grid — one tile per nav group the signed-in user can reach.

  `sidebar: false`, because this page *is* the grid: a rail beside it would
  list what the page already shows.
  """
  use ExampleWeb, :live_view

  import AshQuick.LiveView.Components.NavGrid

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Home") |> assign(sidebar: false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 max-w-5xl mx-auto space-y-6">
      <header>
        <h1 class="text-2xl font-semibold">AshQuick example</h1>
        <p class="text-base-content/70">
          Signed in as <span class="font-medium">{@scope.current_user.name}</span>
          ({@scope.current_user.role}). The tiles below are <code>ExampleWeb.Nav</code>
          filtered through <code>ExampleWeb.AccessControl</code>
          — sign in as another role and the grid changes with it.
        </p>
      </header>

      <.nav_grid scope={@scope} />
    </div>
    """
  end
end
