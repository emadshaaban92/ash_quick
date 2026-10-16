defmodule AshQuick.LiveView.Components.ActionModal do
  @moduledoc false
  use Phoenix.Component
  use Gettext, backend: AshQuick.Gettext
  import AshQuick.Components

  attr :close, :any,
    required: true,
    doc: "the path of the page the modal opened over, or a `JS` command that closes it in place"

  slot :inner_block, required: true

  # Closing is a patch back to the page underneath, which reloads it: whatever
  # the action changed is on it when the modal goes. A bulk action closes by an
  # event instead, since a patch would drop the selection it was opened over.
  #
  # Only ✕ and Cancel close it. Escape would also reach it from inside a
  # dropdown that closes on Escape, and a tap outside is easy to make by
  # accident on a phone: both would throw away what was typed.
  #
  # Nor does it close while a form in it submits: that patch would race the
  # one a successful run makes, and reads as abandoning a run that goes on.
  # LiveView disables only what is in the form, so the ✕ is swapped for a
  # disabled twin while any form here loads, a custom template's included.
  # Hidden, the live one is out of reach of the keyboard too, which
  # pointer-events alone would leave it within.
  def action_modal(assigns) do
    ~H"""
    <dialog id="ash-quick-action-modal" class="modal modal-open">
      <div class="modal-box group/modal w-11/12 max-w-5xl p-0">
        <.link
          {close_attrs(@close)}
          class={[close_class(), "group-has-[form.phx-submit-loading]/modal:hidden"]}
          aria-label={gettext("Close")}
        >
          <.icon name="hero-x-mark" class="w-5 h-5" />
        </.link>
        <button
          type="button"
          disabled
          data-close-while-submitting
          class={[close_class(), "hidden group-has-[form.phx-submit-loading]/modal:inline-flex"]}
          aria-label={gettext("Close")}
        >
          <.icon name="hero-x-mark" class="w-5 h-5" />
        </button>
        {render_slot(@inner_block)}
      </div>
    </dialog>
    """
  end

  @doc false
  def close_attrs(path) when is_binary(path), do: [patch: path]
  def close_attrs(%Phoenix.LiveView.JS{} = js), do: ["phx-click": js]

  @doc false
  def close_js(path) when is_binary(path), do: Phoenix.LiveView.JS.patch(path)
  def close_js(%Phoenix.LiveView.JS{} = js), do: js

  defp close_class, do: "btn btn-sm btn-circle btn-ghost absolute right-3 top-3 z-10"
end
