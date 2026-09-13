defmodule AshQuick.LiveView.Impersonation do
  @moduledoc """
  The commands that end a tab's impersonation, for a host's own markup.

  Impersonation lives in the browser tab rather than on the actor's account, so
  ending one is a client-side act: drop the token and reconnect. Both commands
  below dispatch a DOM event that `assets/js/ash_quick/browser_session.js` is
  listening for.

  They exist so that no host has to spell an event name this library owns. A
  misspelling renders a control that looks right and does nothing, and nothing
  in a test suite would say so.

      <.link phx-click={AshQuick.LiveView.Impersonation.end_impersonation()}>
        End Impersonation
      </.link>

      <a href={~p"/sign-out"} phx-click={AshQuick.LiveView.Impersonation.clear_impersonation()}>
        Sign out
      </a>

  `AshQuick.LiveView.Components.ImpersonationBanner` already carries an end
  control, so a host that renders the banner needs these only for the ones it
  puts elsewhere — a user menu, a mobile drawer, and every sign-out link.

  The mount-time half of impersonation — resolving the token, registering the
  tab and receiving a revocation — is `AshQuick.LiveView.Mount`.
  """

  alias Phoenix.LiveView.JS

  # The tab's whole contract with `impersonation.js`. Held here so the markup
  # that dispatches them cannot drift from the strings the client listens for.
  @end_event "ash_quick:end-impersonation"
  @clear_event "ash_quick:clear-impersonation"

  @doc """
  Drops the tab's token and reconnects, remounting it as its real actor.

  The command behind an "End Impersonation" control.
  """
  def end_impersonation(js \\ %JS{}), do: JS.dispatch(js, @end_event)

  @doc """
  Drops the tab's token without reconnecting.

  What a sign-out link needs: `sessionStorage` outlives the session cookie, so
  a tab that signed out still holding its token would resume the impersonation
  at the next login.
  """
  def clear_impersonation(js \\ %JS{}), do: JS.dispatch(js, @clear_event)
end
