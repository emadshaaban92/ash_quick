defmodule AshQuick.LiveView.Components.ImpersonationBanner do
  @moduledoc false
  # Says out loud that this tab is somebody else, and offers the way back.
  #
  # This is an interlock, not decoration. Impersonation is accountable because
  # `AshQuick.Impersonation.Verifier` refuses an actor resource whose
  # `:impersonate` is not audited — but an audit trail nobody can see while
  # they are acting is only half of that. Without this, a tab standing in for
  # another person is indistinguishable from an ordinary session, and every
  # write it makes is attributed to somebody who is not at the keyboard.
  #
  # It renders nothing when there is nothing to say, so a host places it once
  # and forgets it. It carries its own end control for the same reason the
  # notice exists: whoever reads it has to be able to act on it without going
  # looking for a menu.
  use Phoenix.Component
  use Gettext, backend: AshQuick.Gettext

  import AshQuick.Components

  alias AshQuick.LiveView.Impersonation

  attr :scope, :any,
    required: true,
    doc: "The mount's scope. Nothing renders unless it is impersonating."

  attr :class, :string, default: nil, doc: "Classes for the wrapper."

  attr :end_label, :string,
    default: nil,
    doc: "Text of the control that ends the impersonation."

  def impersonation_banner(assigns) do
    assigns =
      assigns
      |> assign(:actor, impersonating_actor(assigns.scope))
      |> assign(:actor_label, assigns.scope |> impersonating_actor() |> actor_label())

    ~H"""
    <div
      :if={@actor}
      class={["flex items-center gap-2 text-sm", @class]}
      role="status"
      data-ash-quick-impersonating
    >
      <.icon name="hero-eye" class="w-4 h-4 shrink-0" />
      <span class="truncate">
        {gettext("You're impersonating %{actor}", actor: @actor_label)}
      </span>
      <button
        type="button"
        phx-click={Impersonation.end_impersonation()}
        class="shrink-0 underline underline-offset-2 font-semibold hover:no-underline"
      >
        {@end_label || gettext("End")}
      </button>
    </div>
    """
  end

  # Read through the scope contract rather than off a field name, so a host's
  # own spelling of "who is this" never reaches here.
  defp impersonating_actor(scope) do
    if AshQuick.Scope.impersonating?(scope), do: AshQuick.Scope.actor(scope)
  end

  # The resource's declared label, which is how every other AshQuick surface
  # names a record.
  defp actor_label(nil), do: nil

  defp actor_label(actor) do
    AshQuick.Info.display_value(actor) ||
      to_string(AshQuick.Impersonation.Token.identifier(actor))
  end
end
