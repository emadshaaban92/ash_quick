defmodule AshQuick.BrowserSession do
  @moduledoc """
  One browser tab's sign-in: who is at it, since when, from where, and whoever
  they are standing in for.

  Not the session cookie. A cookie is the browser's and every tab shares it;
  this is one tab's, and two tabs of one login are two of these. That is the
  unit support asks about — somebody says "I have it open twice and only one of
  them is wrong".

  A tab outlives the LiveView process behind it, since a refresh or a reconnect
  starts a new one, so `:id` is minted in the browser and replayed on every
  connect rather than assigned per mount. `AshQuick.LiveView.Mount` builds this
  and `AshQuick.BrowserSessionPresence.track_session/2` registers it.

  `:actor` is who the tab is acting as, `nil` on an ordinary session and set
  while impersonating. That is the whole difference between the two: a tab that
  starts standing in for somebody is the same session in a new state, not a new
  session, so it keeps its id and its place in the register.

  A tab that is nobody at all — signed out, or a disconnected render, which has
  no connect params to carry an id — has no session. The assign is `nil`, not a
  struct with empty fields.
  """

  defstruct [:id, :real_actor, :started_at, :ip, :actor, :impersonating_since]

  @doc "Whether this tab is acting as somebody other than whoever signed in."
  def impersonating?(%__MODULE__{actor: nil}), do: false
  def impersonating?(%__MODULE__{}), do: true
end
