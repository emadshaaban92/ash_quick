defmodule ExampleWeb.SqlSandbox do
  @moduledoc """
  Lets a browser test's LiveViews share the test's database transaction.

  A browser test (`test/browser`) drives the page from a real browser, so the
  LiveView serving it is a process no test started and the Ecto sandbox knows
  nothing of. The browser carries the test's sandbox metadata in its
  `User-Agent`, `Phoenix.Ecto.SQL.Sandbox` in the endpoint allows the requests
  it makes, and this mount stage allows the LiveView process the socket starts.

  Both are compiled in only when `config :example, :sql_sandbox` is set, which
  only `config/test.exs` does. The stage goes first in every live session, ahead
  of anything that reads the database.
  """

  import Phoenix.LiveView

  @doc false
  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      socket
      |> get_connect_info(:user_agent)
      |> Phoenix.Ecto.SQL.Sandbox.allow(Ecto.Adapters.SQL.Sandbox)
    end

    {:cont, socket}
  end
end
