defmodule ExampleWeb.SessionController do
  @moduledoc """
  Sign in as one of the seeded users, and sign out again.

  There is no password: this application demonstrates AshQuick, and the only
  thing it needs from authentication is a `user_id` in the session for
  `ExampleWeb.UserAuth` to read back.
  """
  use ExampleWeb, :controller

  alias Example.Accounts.User

  def create(conn, %{"user_id" => user_id}) do
    case Ash.get(User, user_id, authorize?: false) do
      {:ok, user} ->
        conn
        |> renew_session()
        |> put_session(:user_id, user.id)
        |> put_flash(:info, "Signed in as #{user.name}.")
        |> redirect(to: ~p"/")

      {:error, _not_found} ->
        conn
        |> put_flash(:error, "No such user.")
        |> redirect(to: ~p"/login")
    end
  end

  def delete(conn, _params) do
    conn
    |> renew_session()
    |> put_flash(:info, "Signed out.")
    |> redirect(to: ~p"/login")
  end

  # A fresh session id on every sign-in and sign-out, so a fixated one cannot
  # survive the boundary.
  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end
end
