defmodule ExampleWeb.Sessions do
  @moduledoc """
  The two things a test has to say before it can drive a page: who is signed
  in, and which browser tab they are doing it in.

  Both are things the real client supplies and a test has no browser to get
  them from. `log_in/2` writes the session key `ExampleWeb.UserAuth` reads, and
  `in_tab/2` / `impersonating/2` write the LiveSocket connect params
  `deps/ash_quick/assets/js/browser_session.js` replays on every connect.

  The tab half matters more than it looks. AshQuick resolves an impersonation
  per *tab*, not per session, so "an admin impersonating in one window and
  themselves in another" is two conns carrying different connect params — which
  is only expressible if a test can mint and replay a tab identity by hand.
  """

  alias Phoenix.LiveViewTest

  @doc "Signs `user` in on `conn`."
  def log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  @doc """
  Gives `conn` a tab identity, the way the browser's `sessionStorage` does.

  Pass an id to replay an existing tab; leave it out and this is a tab that has
  just been opened. A conn without one stands for an older client, which
  AshQuick still resolves by falling back to whatever the connect params carry.
  """
  def in_tab(conn, tab \\ new_tab())

  def in_tab(conn, %{"id" => _id} = tab), do: merge_connect_params(conn, %{"tab" => tab})
  def in_tab(conn, id) when is_binary(id), do: in_tab(conn, new_tab(id))

  @doc """
  A freshly opened tab's identity, to replay across several connections of it.

  A real tab stores this once and sends the same map back every time, so a test
  standing in for a reconnect reuses the value — a new one is a second tab.
  """
  def new_tab(id \\ Ash.UUID.generate()) do
    %{"id" => id, "started_at" => DateTime.to_iso8601(DateTime.utc_now())}
  end

  @doc """
  Puts a tab into impersonation, the way the browser does.

  The tab already named by `in_tab/2` keeps its identity: starting to
  impersonate is a state the same tab enters, not a new tab.
  """
  def impersonating(conn, token) do
    conn
    |> ensure_tab()
    |> merge_connect_params(%{"impersonation" => token})
  end

  defp ensure_tab(conn) do
    case conn.private[:live_view_connect_params] do
      %{"tab" => _tab} -> conn
      _params -> in_tab(conn)
    end
  end

  # `put_connect_params/2` replaces the whole map, and a tab replays everything
  # it holds on every connect.
  defp merge_connect_params(conn, params) do
    existing = conn.private[:live_view_connect_params] || %{}
    LiveViewTest.put_connect_params(conn, Map.merge(existing, params))
  end
end
