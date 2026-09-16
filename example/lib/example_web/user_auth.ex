defmodule ExampleWeb.UserAuth do
  @moduledoc """
  Who this request is, and whether they may be on this page.

  There is no password anywhere in this application: `ExampleWeb.SessionController`
  signs a seeded user in by id and this module reads that id back. Authentication
  is the host's problem and not AshQuick's, and a real one would only obscure
  the two seams worth seeing here — how a scope is assembled, and where route
  access is enforced.

  The four mount stages run in this order, and every step of it matters:

      on_mount: [
        {ExampleWeb.UserAuth, :assign_current_user},
        AshQuick.LiveView.Mount,
        {ExampleWeb.UserAuth, :assign_scope},
        {ExampleWeb.UserAuth, :require_user}
      ]

  `:assign_current_user` first, because `AshQuick.LiveView.Mount` resolves the
  tab's impersonation against whoever is really signed in and reads them out of
  that assign. Then `Mount`, which turns the tab's token into an actor and reads
  the address it connected from. Then `:assign_scope`, which consumes both.

  Each of the two orderings fails silently rather than loudly. `Mount` ahead of
  `:assign_current_user` sees nobody signed in, so no tab is registered and no
  token resolves — `/browser_sessions` is empty and the banner never appears.
  `:assign_scope` ahead of `Mount` builds a scope that is always the real user,
  with the same result. Both serve every page perfectly well.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias AshQuick.LiveView.Mount
  alias Example.Accounts.User
  alias Example.Scope

  use ExampleWeb, :verified_routes

  @doc "Puts the signed-in user on the conn, if the session names one."
  def fetch_current_user(conn, _opts) do
    assign(conn, :current_user, session_user(get_session(conn, :user_id)))
  end

  @doc """
  Builds the scope for the dead render and for anything served by a controller.

  Also puts the actor's language on the process. This is the render the browser
  gets *first*, so skipping it here means every page flashes English before the
  socket connects.
  """
  def assign_scope(conn, _opts) do
    scope = Scope.new(actor: conn.assigns[:current_user], ip: peer_ip(conn))

    put_locale(scope)

    assign(conn, :scope, scope)
  end

  @doc "Redirects to the sign-in page when nobody is signed in."
  def require_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn |> redirect(to: ~p"/login") |> halt()
    end
  end

  @doc """
  Puts the signed-in user on the socket, before anything reads it.

  This stage has to run *ahead of* `AshQuick.LiveView.Mount`, which resolves the
  tab's impersonation token against whoever is really signed in and reads that
  person out of this assign (`config :ash_quick, actor_assign:`). An app using
  AshAuthentication gets the stage for free from
  `ash_authentication_live_session`; one that authenticates by hand, as this one
  does, has to put it in front itself.

  Leaving it out fails silently and completely: `Mount` sees nobody signed in,
  so no tab is registered, `/browser_sessions` is permanently empty, and no
  impersonation token can ever resolve — while every page still serves.
  """
  def on_mount(:assign_current_user, _params, session, socket) do
    {:cont,
     Phoenix.Component.assign_new(socket, :current_user, fn ->
       session_user(session["user_id"])
     end)}
  end

  # Runs after `AshQuick.LiveView.Mount`, which turned this tab's token into an
  # actor and read the address it connected from. Both are read back here rather
  # than worked out again.
  def on_mount(:assign_scope, _params, _session, socket) do
    scope =
      Scope.new(
        actor: socket.assigns.current_user,
        impersonating: Mount.actor(socket),
        ip: Mount.ip(socket)
      )

    locale = put_locale(scope)

    {:cont,
     socket
     |> Phoenix.Component.assign(:scope, scope)
     |> Phoenix.Component.assign(:current_user, scope.current_user)
     |> Phoenix.Component.assign(:real_user, scope.real_user)
     |> Phoenix.Component.assign(:connected?, Phoenix.LiveView.connected?(socket))
     |> push_document_locale(locale)}
  end

  def on_mount(:require_user, _params, _session, socket) do
    case socket.assigns.scope do
      %{real_user: nil} ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}

      _signed_in ->
        {:cont, attach_route_access_hook(socket)}
    end
  end

  def on_mount(:require_no_user, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    else
      {:cont, socket}
    end
  end

  # Every navigation, not only the first: a live-navigated patch to a page the
  # role does not hold has to be refused the same way a fresh load is.
  defp attach_route_access_hook(socket) do
    Phoenix.LiveView.attach_hook(socket, :route_access, :handle_params, fn
      _params, uri, socket ->
        path = URI.parse(uri).path
        scope = socket.assigns.scope

        # The page a navigation landed on, which the layout reads back:
        # `ExampleWeb.Layouts.nav?/1` draws no sidebar without it, and the
        # sidebar marks the current entry by it.
        socket = Phoenix.Component.assign(socket, :current_path, path)

        cond do
          ExampleWeb.AccessControl.can_access?(scope, path) ->
            {:cont, socket}

          # Raising here would be a trap: the dead render ran as the real user,
          # who can reach more, so only the connected mount would fail — and the
          # reload the client answers with lands on the same page and fails
          # again. Take them somewhere they can be this user instead.
          scope.impersonating_mode ->
            {:halt,
             socket
             |> Phoenix.LiveView.put_flash(
               :error,
               "#{scope.current_user.name} can't access #{path}."
             )
             |> Phoenix.LiveView.push_navigate(to: ~p"/")}

          true ->
            raise ExampleWeb.NotAllowedError, path: path, user: scope.current_user
        end
    end)
  end

  # `Gettext.put_locale/1` is process-wide rather than per-backend, so this one
  # call covers `AshQuick.Gettext` and this application's own.
  defp put_locale(scope) do
    locale = AshQuick.Scope.locale(scope)
    Gettext.put_locale(locale)
    locale
  end

  # The dead render already carried `lang` and `dir` — but it was rendered before
  # the tab said who it is, so an impersonating tab's first paint is the *real*
  # user's language. The connected mount is the first moment the answer is known,
  # and `deps/ash_quick/assets/js/locale.js` is what applies it to `<html>`.
  defp push_document_locale(socket, locale) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.LiveView.push_event(socket, "locale", %{
        lang: locale,
        dir: AshQuick.Locale.direction(locale)
      })
    else
      socket
    end
  end

  defp session_user(nil), do: nil

  defp session_user(user_id) do
    case Ash.get(User, user_id, authorize?: false) do
      {:ok, user} -> user
      {:error, _not_found} -> nil
    end
  end

  defp peer_ip(%Plug.Conn{remote_ip: nil}), do: nil
  defp peer_ip(%Plug.Conn{remote_ip: remote_ip}), do: remote_ip |> :inet.ntoa() |> to_string()
end
