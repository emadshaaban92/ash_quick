defmodule Example.Test.NestedGateLive do
  @moduledoc """
  A routed page that renders, with `live_render/3`, a LiveView declaring
  `AshQuick.LiveView.RouteGate` with its own `on_mount`.

  A nested child inherits its parent's router, and LiveView refuses a
  `handle_params` hook anywhere but the root, so the gate has to let a nested
  child through rather than attach to it. The page that rendered it is the one
  with a path.
  """
  use Phoenix.LiveView

  @impl true
  def render(assigns) do
    ~H"""
    <div id="nested-gate-parent">
      {live_render(@socket, Example.Test.NestedGateLive.Child, id: "nested-gate-child")}
    </div>
    """
  end
end

defmodule Example.Test.NestedGateLive.Child do
  @moduledoc "Runs the route gate itself, and is only ever rendered nested."
  use Phoenix.LiveView

  on_mount {AshQuick.LiveView.RouteGate, access_control: ExampleWeb.AccessControl}

  @impl true
  def render(assigns), do: ~H|<p id="nested-gate-child-body">Rendered nested</p>|
end
