defmodule AshQuick.LiveView.Components.ActionModal do
  @moduledoc false
  use Phoenix.Component
  use Gettext, backend: AshQuick.Gettext
  import AshQuick.Components

  attr :close, :any,
    required: true,
    doc: "the path of the page the modal opened over, or a `JS` command that closes it in place"

  attr :id, :string, default: "ash-quick-action-modal"
  attr :class, :any, default: nil, doc: "the box's size and padding"

  slot :title, doc: "a heading drawn above the content, which names the dialog"
  slot :inner_block, required: true

  # Every AshQuick modal is this one: an action's form, a bulk action, the
  # list's filter and its export. The action's form and the filter close by a
  # patch back to the page underneath, which reloads it: whatever the action
  # changed is on it when the modal goes. A bulk action and the export close
  # by an event instead, since a patch would drop the selection a bulk action
  # was opened over, and the export has nothing to reload.
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
    <dialog
      id={@id}
      class="modal modal-open"
      aria-labelledby={@title != [] && "#{@id}-title"}
    >
      <div class={["modal-box group/modal", @class]}>
        <.link
          {close_attrs(@close)}
          class={[close_class(@title), "group-has-[form.phx-submit-loading]/modal:hidden"]}
          aria-label={gettext("Close")}
        >
          <.icon name="hero-x-mark" class="w-5 h-5" />
        </.link>
        <button
          type="button"
          disabled
          data-close-while-submitting
          class={[
            close_class(@title),
            "hidden group-has-[form.phx-submit-loading]/modal:inline-flex"
          ]}
          aria-label={gettext("Close")}
        >
          <.icon name="hero-x-mark" class="w-5 h-5" />
        </button>
        <h3 :if={@title != []} id={"#{@id}-title"} class="text-lg font-semibold mb-4 pe-10">
          {render_slot(@title)}
        </h3>
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

  # Untitled, the box has no padding (the action's form brings its own), so
  # the ✕ sits in the corner. Titled, the box keeps daisyUI's 24px padding,
  # and the ✕ is centred on the title's line with its edge on the content's.
  # Logical sides (`end-`, `pe-`), so in a right-to-left locale the ✕ ends
  # the title's line on the left, as a flex header would put it.
  defp close_class([]), do: "btn btn-sm btn-circle btn-ghost absolute end-3 top-3 z-10"
  defp close_class(_title), do: "btn btn-sm btn-circle btn-ghost absolute end-6 top-5.5 z-10"
end
