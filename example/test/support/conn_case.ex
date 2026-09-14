defmodule ExampleWeb.ConnCase do
  @moduledoc """
  Tests that drive a page.

  `log_in/2` puts a user in the session the way `ExampleWeb.SessionController`
  does, which is all `ExampleWeb.UserAuth` reads — so a test signs in by naming
  a user rather than by filling in a form that has no password anyway.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint ExampleWeb.Endpoint

      use ExampleWeb, :verified_routes

      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import Plug.Conn
      import ExampleWeb.ConnCase
      import Example.Fixtures
    end
  end

  setup tags do
    Example.DataCase.setup_sandbox(tags)

    {:ok, Map.merge(Example.Fixtures.roles(), %{conn: Phoenix.ConnTest.build_conn()})}
  end

  @doc "Signs `user` in on `conn`."
  def log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end
end
