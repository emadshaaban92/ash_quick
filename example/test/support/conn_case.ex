defmodule ExampleWeb.ConnCase do
  @moduledoc """
  Tests that drive a page through `Phoenix.LiveViewTest` directly.

  `ExampleWeb.FeatureCase` is the one to reach for: it drives the same pages
  through `PhoenixTest`, and its assertions are about what a reader sees. This
  case is for the tests that need the LiveView itself — a mount asserted to
  raise, a `render_click/2` for an event no button offers, a socket's assigns
  read back.

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
      import Example.Fixtures
      import ExampleWeb.Sessions
    end
  end

  setup tags do
    Example.DataCase.setup_sandbox(tags)

    {:ok, Map.merge(Example.Fixtures.roles(), %{conn: Phoenix.ConnTest.build_conn()})}
  end
end
