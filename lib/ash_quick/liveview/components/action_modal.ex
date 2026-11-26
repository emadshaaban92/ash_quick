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

  attr :flash, :map,
    default: %{},
    doc: "the page's flash, drawn in the box while the modal is open"

  slot :title, doc: "a heading drawn above the content, which names the dialog"
  slot :inner_block, required: true

  # Every AshQuick modal is this one: an action's form, a bulk action, the
  # list's filter and its export. The action's form and the filter close by a
  # patch back to the page underneath, which reloads it: whatever the action
  # changed is on it when the modal goes. A bulk action and the export close
  # by an event instead, since a patch would drop the selection a bulk action
  # was opened over, and the export has nothing to reload.
  #
  # A real modal dialog: the hook opens it with `showModal()`, so the browser
  # keeps the keyboard and a screen reader inside it and the page underneath
  # inert, and gives the focus back to what opened it once it goes. It is
  # drawn open (`modal-open`) as well, so it shows before the hook runs.
  #
  # Only ✕ and Cancel close it. Escape would also reach it from inside a
  # dropdown that closes on Escape, and a tap outside is easy to make by
  # accident on a phone: both would throw away what was typed. So the hook
  # refuses the browser's Escape (and a phone's back gesture), and reopens the
  # dialog should a browser close it anyway: it is the server's to close.
  #
  # A flash raised while it is open (a refused run, a save that failed with
  # no field to show it at, a file not stored) is drawn in the box too, as
  # an alert: the host's flash sits outside the dialog, under its backdrop,
  # inert, where it is neither readable nor read out. Its ✕ clears the flash,
  # the host's copy with it.
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
      class="modal modal-open outline-none"
      aria-labelledby={@title != [] && "#{@id}-title"}
      tabindex="-1"
      phx-hook=".ActionModal"
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
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
        <div
          :for={{kind, message} <- flash_messages(@flash)}
          id={"#{@id}-flash-#{kind}"}
          role="alert"
          class={[
            "alert alert-soft text-sm flex items-start",
            kind == :error && "alert-error",
            kind == :info && "alert-info",
            if(@title == [], do: "m-4 me-14", else: "mb-4")
          ]}
        >
          <.icon
            name={if kind == :error, do: "hero-exclamation-circle", else: "hero-information-circle"}
            class="w-5 h-5 shrink-0"
          />
          <span class="flex-1 min-w-0 break-words">{message}</span>
          <button
            type="button"
            class="btn btn-ghost btn-xs btn-square"
            aria-label={gettext("Dismiss")}
            phx-click={Phoenix.LiveView.JS.push("lv:clear-flash", value: %{key: kind})}
          >
            <.icon name="hero-x-mark" class="w-4 h-4" />
          </button>
        </div>
        {render_slot(@inner_block)}
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ActionModal">
      // The last control focused on the page. By the time the server's reply
      // draws the modal, the page under it may have been drawn again and the
      // control that asked for it lost the focus with its old node, so the
      // modal looks for it again once it closes (see `found/1`).
      let lastFocused = null
      document.addEventListener("focusin", (event) => {
        if (!event.target.closest("dialog")) lastFocused = event.target
      })

      export default {
        mounted() {
          const at = document.activeElement
          this.opener = at && at !== document.body && !this.el.contains(at) ? at : lastFocused
          this.el.addEventListener("cancel", (event) => event.preventDefault())
          this.el.addEventListener("keydown", (event) => {
            if (event.key === "Escape") event.preventDefault()
          })
          // A browser may close a modal on a second Escape whatever the page
          // says. The server still draws it, so it opens again.
          this.el.addEventListener("close", () => {
            if (this.el.isConnected) this.show()
          })
          this.show()
        },
        show() {
          if (this.el.matches(":modal")) return
          if (this.el.open) this.el.close()
          this.el.showModal()
          // The dialog itself takes the focus, so a screen reader names it
          // and Tab goes on to its first control, rather than the browser's
          // pick: the ✕, ringed as though tabbed to, or the scrolling box.
          if (!this.el.querySelector("[autofocus]")) this.el.focus({preventScroll: true})
        },
        // A frame on, once the patch that closed the modal has settled, and
        // unless the focus has gone somewhere of its own.
        destroyed() {
          const opener = this.opener
          const dialog = this.el
          requestAnimationFrame(() => {
            const at = document.activeElement
            const lost = !at || at === document.body || !at.isConnected || dialog.contains(at)
            if (lost && opener) found(opener)?.focus({preventScroll: true})
          })
        }
      }

      // The opener itself while it is on the page, else the control drawn in
      // its place. Most of AshQuick's buttons (a list's Create, a details
      // page's actions) and many a host's carry no id, but what they do names
      // them: the event their click pushes, or the page their link goes to.
      // Only a control that alone matches is taken, never a guess between two.
      function found(opener) {
        if (opener.isConnected) return opener
        if (opener.id) return document.getElementById(opener.id)
        for (const name of ["phx-click", "href"]) {
          const value = opener.getAttribute(name)
          if (!value) continue
          const same = [...document.querySelectorAll(`${opener.localName}[${name}]`)]
            .filter((el) => el.getAttribute(name) === value && !el.closest("dialog"))
          return same.length === 1 ? same[0] : null
        }
        return null
      }
    </script>
    """
  end

  defp flash_messages(flash) do
    for kind <- [:error, :info],
        message = Phoenix.Flash.get(flash, kind),
        message,
        do: {kind, message}
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
