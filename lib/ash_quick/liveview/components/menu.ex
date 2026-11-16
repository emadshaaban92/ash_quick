defmodule AshQuick.LiveView.Components.Menu do
  @moduledoc false
  use Phoenix.Component

  # Every AshQuick dropdown: a row's actions, a cell's filter entries, the
  # list's Export and Actions, its saved filters, and a details page's More
  # actions. A button opens it, and only that button: it is a daisyUI
  # dropdown held shut by `dropdown-close` and opened by `dropdown-open`, so
  # tabbing past the button no longer opens it, as daisyUI's focus-within
  # variant did.
  #
  # Its box takes the focus (`tabindex="-1"`) when a click inside it lands
  # on nothing focusable, a label or its padding, so the click keeps it open
  # rather than reading as focus leaving it.
  #
  # The keys are a menu button's (WAI-ARIA's menu button pattern). Enter,
  # Space or ↓ on the button opens it on its first entry, ↑ on its last; ↓
  # and ↑ move between the entries, Home and End to either end, and Escape
  # closes it back onto the button. Tab, a click outside or focus leaving it
  # close it too, and so does picking an entry, which hands the focus back to
  # the button: what the entry opened, a modal, takes it from there.
  #
  # `kind: :panel` is a disclosure instead, for a box of checkboxes rather
  # than a list of commands: the button says whether it is open and Escape
  # closes it, and Tab walks its contents as it does a page's.
  #
  # Entries are marked by the caller, `role="menuitem"` on what is clicked
  # and `role="none"` on its `<li>`, since the entries are drawn by the
  # callers' own components. An entry the hook finds disabled
  # (`aria-disabled`) is skipped. The entries of a menu whose button asks
  # the server for them (`phx-click` on the trigger) arrive after it opens,
  # and the first or last is focused as they do.

  @doc """
  The hook a page's section carries so its menus answer: one for all of
  them, rather than one each. The section needs an id.
  """
  def hook, do: "AshQuick.LiveView.Components.Menu.Menus"

  attr :id, :string, required: true
  attr :class, :any, default: nil, doc: "the wrapper's classes, such as `dropdown-end`"
  attr :trigger_class, :any, default: "btn btn-outline btn-sm"
  attr :content_class, :any, required: true
  attr :kind, :atom, values: [:menu, :panel], default: :menu
  attr :label, :string, default: nil, doc: "the button's name, when its content does not give one"
  attr :title, :string, default: nil
  attr :on_open, :any, default: nil, doc: "a `JS` command run as the button is clicked"
  attr :rest, :global, doc: "attributes for the wrapper"

  slot :trigger, required: true
  slot :inner_block, required: true

  def menu(assigns) do
    ~H"""
    <div
      id={@id}
      class={["dropdown dropdown-close", @class]}
      data-menu={@kind}
      {@rest}
    >
      <button
        type="button"
        id={"#{@id}-trigger"}
        class={@trigger_class}
        aria-haspopup={@kind == :menu && "menu"}
        aria-expanded="false"
        aria-controls={"#{@id}-content"}
        aria-label={@label}
        title={@title}
        phx-click={@on_open}
        data-menu-trigger
      >
        {render_slot(@trigger)}
      </button>
      <.content id={"#{@id}-content"} kind={@kind} class={@content_class} trigger={"#{@id}-trigger"}>
        {render_slot(@inner_block)}
      </.content>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Menus">
      // One hook for every menu on a page, on the page's section
      // (`Menu.hook/0`), its listeners delegated from there: a list holds a
      // menu per row and per filterable cell, thousands on a long page, and a
      // hook each would cost a mount and a page-wide listener each.
      //
      // A menu is opened and closed through `js()`, so its state outlives
      // the server's patches of it, which always render it shut. `js()`
      // changes a class on the next frame, so which menu is open is held
      // here, by id, and an entry is focused a frame later, once it shows.
      // One menu is open at a time.
      //
      // An entry picked hands the focus back to the menu's button, but what
      // it did may draw the button's row again, the new button in place of
      // the focused one. The button's id is kept for a moment, so the focus
      // goes back to the one drawn in its place.
      export default {
        mounted() {
          this.openId = null
          this.el.addEventListener("click", (event) => this.clicked(event))
          this.el.addEventListener("keydown", (event) => this.keydown(event))
          this.el.addEventListener("focusout", (event) => {
            const menu = this.openMenu()
            if (menu && !menu.contains(event.relatedTarget)) this.close(menu, false)
          })
          this.outside = (event) => {
            const menu = this.openMenu()
            if (menu && !menu.contains(event.target)) this.close(menu, false)
          }
          document.addEventListener("pointerdown", this.outside)
          this.observer = new MutationObserver(() => this.patched())
          this.observer.observe(this.el, {childList: true, subtree: true})
        },
        destroyed() {
          document.removeEventListener("pointerdown", this.outside)
          this.observer.disconnect()
        },
        menuOf(node) { return node instanceof Element ? node.closest("[data-menu]") : null },
        openMenu() {
          const menu = this.openId && document.getElementById(this.openId)
          return menu && this.el.contains(menu) ? menu : null
        },
        trigger(menu) { return menu.querySelector(":scope > [data-menu-trigger]") },
        content(menu) { return menu.querySelector(":scope > [data-menu-content]") },
        items(menu) {
          return [...this.content(menu).querySelectorAll("[role=menuitem]")]
            .filter((item) => item.getAttribute("aria-disabled") !== "true")
        },
        clicked(event) {
          const menu = this.menuOf(event.target)
          if (!menu) return
          if (event.target.closest("[data-menu-trigger]")) {
            // A click from Enter or Space carries no pointer, `detail` 0:
            // the keyboard opens onto the first entry.
            if (this.openMenu() === menu) this.close(menu, false)
            else this.open(menu, event.detail === 0 ? "first" : null)
          } else if (menu.dataset.menu === "menu" && event.target.closest("[role=menuitem]")) {
            this.picked = {id: this.trigger(menu).id, at: Date.now()}
            this.close(menu, true)
          }
        },
        keydown(event) {
          const menu = this.menuOf(event.target)
          if (!menu) return
          const open = this.openMenu() === menu
          if (event.key === "Escape" && open) {
            event.preventDefault()
            event.stopPropagation()
            this.close(menu, true)
            return
          }
          if (menu.dataset.menu !== "menu") return
          if (event.target.closest("[data-menu-trigger]")) {
            if (event.key === "ArrowDown" || event.key === "ArrowUp") {
              event.preventDefault()
              this.open(menu, event.key === "ArrowDown" ? "first" : "last")
            }
            return
          }
          const items = this.items(menu)
          const at = items.indexOf(document.activeElement)
          if (at < 0) return
          const to = {
            ArrowDown: (at + 1) % items.length,
            ArrowUp: (at - 1 + items.length) % items.length,
            Home: 0,
            End: items.length - 1
          }[event.key]
          if (to !== undefined) {
            event.preventDefault()
            items[to].focus()
          } else if (event.key === "Tab") {
            this.close(menu, false)
          }
        },
        open(menu, focus) {
          const other = this.openMenu()
          if (other && other !== menu) this.close(other, false)
          if (other !== menu) {
            this.openId = menu.id
            this.js().removeClass(menu, "dropdown-close")
            this.js().addClass(menu, "dropdown-open")
            this.js().setAttribute(this.trigger(menu), "aria-expanded", "true")
          }
          this.pending = focus
          requestAnimationFrame(() => this.arrived())
        },
        close(menu, refocus) {
          if (this.openId === menu.id) {
            this.openId = null
            this.pending = null
          }
          this.js().removeClass(menu, "dropdown-open")
          this.js().addClass(menu, "dropdown-close")
          this.js().setAttribute(this.trigger(menu), "aria-expanded", "false")
          if (refocus) this.trigger(menu).focus()
        },
        patched() {
          this.arrived()
          this.reclaim()
        },
        // Focuses the entry asked for once there is one: at once for a menu
        // drawn with its entries, on the server's reply for one that is not.
        arrived() {
          const menu = this.pending && this.openMenu()
          if (!menu) return
          const items = this.items(menu)
          if (items.length === 0) return
          const item = this.pending === "last" ? items[items.length - 1] : items[0]
          this.pending = null
          item.focus()
        },
        reclaim() {
          const picked = this.picked
          if (!picked) return
          if (Date.now() - picked.at > 5000) { this.picked = null; return }
          const at = document.activeElement
          if (at && at !== document.body && at.isConnected) return
          const trigger = document.getElementById(picked.id)
          if (trigger && this.el.contains(trigger)) {
            this.picked = null
            trigger.focus({preventScroll: true})
          }
        }
      }
    </script>
    """
  end

  attr :id, :string, required: true
  attr :kind, :atom, required: true
  attr :class, :any, required: true
  attr :trigger, :string, required: true
  slot :inner_block, required: true

  defp content(assigns) do
    assigns
    |> assign(
      :box,
      "bg-base-300 rounded-box z-10 shadow-[0_2px_15px_rgba(0,0,0,0.3)] border border-base-content/10"
    )
    |> drawn()
  end

  defp drawn(%{kind: :menu} = assigns) do
    ~H"""
    <ul
      id={@id}
      role="menu"
      aria-labelledby={@trigger}
      tabindex="-1"
      class={["dropdown-content outline-none", @box, @class]}
      data-menu-content
    >
      {render_slot(@inner_block)}
    </ul>
    """
  end

  defp drawn(assigns) do
    ~H"""
    <div
      id={@id}
      tabindex="-1"
      class={["dropdown-content outline-none", @box, @class]}
      data-menu-content
    >
      {render_slot(@inner_block)}
    </div>
    """
  end
end
