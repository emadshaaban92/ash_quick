defmodule ExampleWeb.LoginLive do
  @moduledoc """
  Pick a demo user and be signed in as them.

  No passwords: what this application is demonstrating is AshQuick, and all
  `ExampleWeb.UserAuth` needs is a `user_id` in the session. Each seeded user
  holds a different role, which is the quickest way to see what
  `ExampleWeb.AccessControl` and the resources' policies actually do to a page.
  """
  use ExampleWeb, :live_view

  alias Example.Accounts.User

  @impl true
  def mount(_params, _session, socket) do
    users =
      User
      |> Ash.Query.sort(role: :asc, name: :asc)
      |> Ash.read!(authorize?: false)

    {:ok,
     socket
     |> assign(page_title: "Sign in")
     |> assign(sidebar: false)
     |> assign(users: users)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 max-w-xl mx-auto space-y-6">
      <header class="space-y-1">
        <h1 class="text-2xl font-semibold">Sign in</h1>
        <p class="text-base-content/70">
          Demo users, one per role. There are no passwords — see <code>ExampleWeb.SessionController</code>.
        </p>
      </header>

      <p :if={@users == []} class="alert alert-warning">
        No users yet. Run <code>mix run priv/repo/seeds.exs</code>.
      </p>

      <ul class="space-y-2">
        <li :for={user <- @users}>
          <.form for={%{}} action={~p"/session"} method="post">
            <input type="hidden" name="user_id" value={user.id} />
            <button type="submit" class="btn btn-block justify-between">
              <span>{user.name}</span>
              <span class="badge badge-neutral">{user.role}</span>
            </button>
          </.form>
        </li>
      </ul>
    </div>
    """
  end
end
