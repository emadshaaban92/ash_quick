defmodule AshQuick.LiveView.Components.ActionModal do
  @moduledoc false
  use Phoenix.Component
  use Gettext, backend: AshQuick.Gettext
  import AshQuick.Components

  attr :close, :string, required: true, doc: "the path of the page the modal opened over"
  slot :inner_block, required: true

  # Closing is a patch back to the page underneath, which reloads it: whatever
  # the action changed is on it when the modal goes.
  #
  # Only ✕ and Cancel close it. Escape would also reach it from inside a
  # dropdown that closes on Escape, and a tap outside is easy to make by
  # accident on a phone: both would throw away what was typed.
  def action_modal(assigns) do
    ~H"""
    <dialog id="ash-quick-action-modal" class="modal modal-open">
      <div class="modal-box w-11/12 max-w-5xl p-0">
        <.link
          patch={@close}
          class="btn btn-sm btn-circle btn-ghost absolute right-3 top-3 z-10"
          aria-label={gettext("Close")}
        >
          <.icon name="hero-x-mark" class="w-5 h-5" />
        </.link>
        {render_slot(@inner_block)}
      </div>
    </dialog>
    """
  end
end
