defmodule AshQuick.Impersonation.NotAllowedError do
  @moduledoc """
  Raised when somebody tries to end an impersonation session they could not
  have started.

  `AshQuick.LiveView.BrowserSessionsLive` refuses outright rather than flashing,
  because the layout that would render the flash is the one a host swaps out
  for the notice it shows role-less and deactivated users — the very users its
  route gate waves through. `plug_status: 403` covers the case where the same
  refusal is reached over HTTP.
  """

  defexception message: "You are not allowed to end that impersonation session.",
               plug_status: 403,
               session_id: nil,
               actor: nil
end
