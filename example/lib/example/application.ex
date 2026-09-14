defmodule Example.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ExampleWeb.Telemetry,
      Example.Repo,
      {Phoenix.PubSub, name: Example.PubSub},
      # After the PubSub server it registers against and before the endpoint
      # whose sockets it counts — the placement `AshQuick`'s README asks for.
      AshQuick.BrowserSessionPresence,
      ExampleWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Example.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ExampleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
