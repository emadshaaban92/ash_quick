defmodule AshQuick.LiveView.Timezone do
  @moduledoc """
  Puts the reader's timezone on every LiveView of a `live_session`.

  A QuickView shows timestamps in `AshQuick.Timezone.current/0`, the zone of
  the reader's scope (`AshQuick.Scope.timezone/1`). This stage puts that zone
  on the LiveView's process, so the host's own LiveViews beside the
  QuickViews format with `AshQuick.Config` in the same zone. It goes after the
  host's scope stage, which is what fills `socket.assigns.scope`:

      on_mount: [
        AshQuick.LiveView.Mount,
        {MyAppWeb.UserAuth, :assign_scope},
        AshQuick.LiveView.Timezone
      ]

  Which zone the scope names is the host's to decide: one kept on the user,
  one for the whole organisation, or the one the browser reports. AshQuick
  reads the scope and nothing else. A QuickView puts the zone on mount as
  well, so one mounted outside such a session reads it too.
  """

  @doc "Puts the scope's zone on the process; see `AshQuick.Timezone.put/1`."
  def on_mount(:default, _params, _session, socket) do
    AshQuick.Timezone.put(AshQuick.Scope.timezone(socket.assigns[:scope]))
    {:cont, socket}
  end
end
