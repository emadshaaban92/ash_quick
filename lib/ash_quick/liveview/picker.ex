defmodule AshQuick.LiveView.Picker do
  @moduledoc false
  # A searchable picker: one value (`mode: :single`) or several shown as tags
  # (`mode: :tags`), in one daisyUI input box. Internal for now, its API free
  # to change, and kept out of `AshQuick.Components`, which a host's QuickView
  # imports whole.
  #
  #     <.live_component
  #       module={AshQuick.LiveView.Picker}
  #       id={"#{@field.id}-picker"}
  #       field={@field}
  #       mode={:tags}
  #       search={&search_brands(&1, @scope)}
  #       resolve={&resolve_brands(&1, @scope)}
  #     />
  #
  # ## Who owns what
  #
  # The server owns everything a form reads: the options, the selection and
  # the hidden inputs. The colocated `.Picker` hook owns what has to feel
  # instant: whether the list is open, which option is active, the keys and
  # the typing debounce. The hook writes only through `this.js()`, whose
  # changes outlive LiveView's patches.
  #
  # ## Callbacks
  #
  #   * `search` takes the typed text, or `nil` for none, and returns options,
  #     or `{options, :more}` when there are more than it returned. It runs in
  #     `start_async/3`, so a slow one never holds the page, and a result older
  #     than the latest search is dropped.
  #   * `resolve` takes the values the field holds that the picker has no
  #     option for, and returns options for those it can. It runs when the
  #     field's value changes from outside the picker: on mount, on a
  #     reconnect's form recovery, on a parent that sets the value. A value it
  #     cannot resolve is kept, never dropped, drawn as "Unavailable" with the
  #     value under it (or as a new value, in `create` mode).
  #
  # An option is a map with `:value` and `:label`, and an optional `:hint`.
  # Any other keys are kept, for the `option` and `tag` slots. Options are told
  # apart by value, compared as text, so two sharing a label never unpick each
  # other.
  #
  # ## What it posts
  #
  # The same as LiveSelect, so `AshQuick.LiveView.FormParams` and
  # `AshQuick.LiveView.FieldErrors` read it unchanged:
  #
  #   * single: `<name>=<value>`, or `<name>=""` once cleared;
  #   * tags: `<name>[]=<value>` for each pick, or only
  #     `<form>[<field>_empty_selection]` once the last is removed.
  #
  # A pick, removal or clear dispatches `input` from the first hidden input
  # once the patch redrawing them lands (`data-changes`), so the form's
  # `phx-change` runs with the field as its `_target`. The text box has no
  # `name`, so typing posts nothing and makes no atom.
  #
  # ## Other assigns
  #
  #   * `clearable` (single): draws a ✕ that empties the field.
  #   * `placeholder`, and `label_id` (for `aria-labelledby`) or `aria_label`.
  #   * `describedby`: ids for `aria-describedby`, help before errors; `nil`s
  #     are dropped. `invalid` sets `aria-invalid` and the box's error colour.
  #   * `create`: offers typed text that matches no option as an "Add" row,
  #     and draws what it adds as a tag marked "new". `create_match: :any_case`
  #     ignores case when matching (for a `ci_string` key).
  #   * `size`: `:md` or `:sm`.
  #   * `class`: overrides for the parts `box`, `input`, `tag`, `popup`,
  #     `option` and `active`.
  #   * slots `option` and `tag`, each given the option.
  use Phoenix.LiveComponent
  use Gettext, backend: AshQuick.Gettext

  @default_classes %{
    box: "input w-full h-auto min-h-(--size) flex items-center gap-1 py-1 cursor-text",
    # A host's base styles for text inputs (`@tailwindcss/forms` gives each
    # a border, padding, a white background and a focus ring) are undone:
    # this box is the text part of the daisyUI box around it.
    input:
      "min-w-0 appearance-none border-0 bg-transparent p-0 shadow-none outline-none " <>
        "text-[length:inherit] leading-[inherit] focus:shadow-none focus:ring-0",
    tag: "badge badge-primary h-auto min-h-6 py-0.5 max-w-full whitespace-normal gap-1",
    popup:
      "absolute z-20 top-full start-0 mt-1 w-full max-h-60 overflow-y-auto rounded-box " <>
        "border border-base-300 bg-base-100 p-1 shadow-lg",
    option:
      "group flex items-start gap-2 rounded-field px-3 py-2 cursor-pointer text-start " <>
        "hover:bg-base-200",
    active: "bg-base-200"
  }

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       selection: [],
       seen: nil,
       known: %{},
       options: [],
       more?: false,
       query: nil,
       searching?: false,
       searched?: false,
       rev: 0,
       changes: 0,
       shown: 0,
       holding: false
     )}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:mode, fn -> :single end)
     |> assign_new(:resolve, fn -> fn _values -> [] end end)
     |> assign_new(:clearable, fn -> false end)
     |> assign_new(:placeholder, fn -> nil end)
     |> assign_new(:label_id, fn -> nil end)
     |> assign_new(:aria_label, fn -> nil end)
     |> assign_new(:describedby, fn -> [] end)
     |> assign_new(:invalid, fn -> false end)
     |> assign_new(:create, fn -> false end)
     |> assign_new(:create_match, fn -> :exact end)
     |> assign_new(:size, fn -> :md end)
     |> assign_new(:class, fn -> %{} end)
     |> assign_new(:option, fn -> [] end)
     |> assign_new(:tag, fn -> [] end)
     |> adopt_value()}
  end

  # The field's value is the selection whenever it changes: the picker's own
  # picks come back through the form as the value it just posted, and anything
  # else (a mount, a recovered form, a parent's reset) is taken as it is. A
  # redraw carrying the value the picker last saw keeps its own selection.
  #
  # So does any redraw while a change of its own waits to be posted
  # (`holding`): one that left before the hook's post, such as another
  # input's change or a live update, carries the field's old value, and
  # adopting it would undo the pick. The hold ends when the form brings the
  # picker's values back, or when the hook says it posted its latest change
  # (`posted`), which then takes whatever the field holds by then.
  defp adopt_value(socket) do
    values = values_of(socket.assigns.field.value, socket.assigns.mode)

    cond do
      values == socket.assigns.seen -> assign(socket, holding: false)
      socket.assigns.holding -> socket
      true -> take_values(socket, values)
    end
  end

  defp take_values(socket, values) do
    %{known: known, resolve: resolve} = socket.assigns
    missing = Enum.reject(values, &Map.has_key?(known, &1))
    known = if missing == [], do: known, else: remember(known, resolve.(missing))

    assign(socket,
      seen: values,
      known: known,
      selection: Enum.map(values, &(Map.get(known, &1) || unresolved(&1, socket.assigns)))
    )
  end

  defp values_of(value, :single) do
    case value do
      empty when empty in [nil, "", []] -> []
      [one | _] -> values_of(one, :single)
      one -> [to_string(one)]
    end
  end

  defp values_of(value, :tags) do
    value
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  defp unresolved(value, %{create: create}) when create not in [false, nil],
    do: %{value: value, label: value, new: true}

  defp unresolved(value, _assigns),
    do: %{value: value, label: gettext("Unavailable"), hint: value, unavailable: true}

  defp remember(known, options),
    do: Enum.reduce(normalize(options), known, &Map.put(&2, &1.value, &1))

  defp normalize(options),
    do: Enum.map(options, &Map.update!(&1, :value, fn v -> to_string(v) end))

  # A pick, removal or clear replies whether the selection changed and, if
  # it did, the count of changes (`data-changes`) the patch drawing it will
  # carry: the reply lands before the patch, so the hook waits for that
  # count before it posts the form. A search carries the hook's own `seq`,
  # drawn back as `data-shown` with its results, so the hook knows which
  # search the list is from.
  #
  # A search overtaken by a newer one is cancelled, not only its result
  # dropped: each holds whatever its lookup holds (a pool connection) until
  # it ends, and one starts at every pause in typing.
  @impl true
  def handle_event("search", params, socket) do
    query =
      case params["text"] do
        text when is_binary(text) -> if String.trim(text) != "", do: String.trim(text)
        _not_text -> nil
      end

    ref = socket.assigns.rev + 1
    seq = if is_integer(params["seq"]), do: params["seq"]
    search = socket.assigns.search

    {:noreply,
     socket
     |> assign(query: query, query_ref: ref, rev: ref, searching?: true, asked: seq)
     |> cancel_async(:search)
     |> start_async(:search, fn -> {ref, seq, search.(query)} end)}
  end

  # The hook has posted the form for a change (`changes`, its count). If it
  # is the latest, the hold ends and the field's value is taken as it now
  # stands. A post for an earlier change carries a selection a newer pick has
  # since grown, so the hold stays until that pick is posted too.
  def handle_event("posted", %{"changes" => changes}, %{assigns: %{changes: changes}} = socket),
    do: {:noreply, socket |> assign(holding: false) |> adopt_value()}

  def handle_event("posted", _params, socket), do: {:noreply, socket}

  def handle_event("pick", %{"value" => value} = params, socket) do
    %{selection: selection, mode: mode} = socket.assigns

    case picked_option(socket.assigns, value, params["new"] in [true, "true"]) do
      nil ->
        {:reply, %{changed: false}, socket}

      option ->
        selection =
          cond do
            mode == :single -> [option]
            Enum.any?(selection, &(&1.value == option.value)) -> drop(selection, option.value)
            true -> selection ++ [option]
          end

        changed(select(socket, selection))
    end
  end

  def handle_event("remove", %{"value" => value}, socket) do
    %{selection: selection} = socket.assigns

    if Enum.any?(selection, &(&1.value == value)),
      do: changed(select(socket, drop(selection, value))),
      else: {:reply, %{changed: false}, socket}
  end

  def handle_event("clear", _params, socket), do: changed(select(socket, []))

  defp changed(socket),
    do: {:reply, %{changed: true, changes: socket.assigns.changes}, socket}

  @impl true
  def handle_async(:search, {:ok, {ref, seq, result}}, %{assigns: %{query_ref: ref}} = socket) do
    {options, more?} =
      case result do
        {options, :more} when is_list(options) ->
          {normalize(options), true}

        options when is_list(options) ->
          {normalize(options), false}

        other ->
          raise ArgumentError,
                "the `search` callback of the picker #{inspect(socket.assigns.id)} must " <>
                  "return a list of options (maps with `:value` and `:label`) or " <>
                  "`{options, :more}`, got: #{inspect(other)}"
      end

    {:noreply,
     assign(socket,
       options: options,
       more?: more?,
       # What it can label without asking `resolve`: what it holds and what it
       # offers now, not every result it ever drew.
       known: remember(%{}, socket.assigns.selection ++ options),
       searching?: false,
       searched?: true,
       shown: seq || socket.assigns.shown,
       rev: socket.assigns.rev + 1
     )}
  end

  # Defensive: LiveView already drops the result of a task a newer
  # `start_async/3` replaced, so a stale result never arrives here.
  def handle_async(:search, {:ok, _stale}, socket), do: {:noreply, socket}

  # The search a newer one cancelled.
  def handle_async(:search, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  # A search that failed answers with nothing, so the hook stops waiting for
  # it. Only the latest search's outcome arrives here, so `asked` is its
  # `seq`.
  def handle_async(:search, {:exit, _reason}, socket) do
    {:noreply,
     assign(socket,
       shown: socket.assigns[:asked] || socket.assigns.shown,
       options: [],
       more?: false,
       searching?: false,
       searched?: true,
       rev: socket.assigns.rev + 1
     )}
  end

  defp picked_option(assigns, value, true = _new) do
    if assigns.create not in [false, nil] and String.trim(value) != "",
      do: %{value: String.trim(value), label: String.trim(value), new: true}
  end

  defp picked_option(assigns, value, false),
    do: Enum.find(assigns.options, &(&1.value == value))

  defp drop(selection, value), do: Enum.reject(selection, &(&1.value == value))

  # The values drawn now are the ones the form will post, so they are what
  # the picker has seen: the form's redraw with them keeps this selection.
  defp select(socket, selection) do
    assign(socket,
      selection: selection,
      holding: true,
      changes: socket.assigns.changes + 1,
      seen: Enum.map(selection, & &1.value),
      known: remember(socket.assigns.known, selection)
    )
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        classes: Map.merge(@default_classes, assigns.class),
        picked: MapSet.new(assigns.selection, & &1.value),
        add: add_text(assigns),
        status: status(assigns),
        listbox_id: "#{assigns.id}-listbox",
        selection_id: "#{assigns.id}-selection"
      )

    ~H"""
    <div
      id={@id}
      phx-hook=".Picker"
      class="relative w-full"
      data-aq-picker={@mode}
      data-rev={@rev}
      data-changes={@changes}
      data-shown={@shown}
      data-active-class={@classes.active}
    >
      <div
        data-part="box"
        class={[
          @classes.box,
          @mode == :tags && "flex-wrap",
          @size == :sm && "input-sm",
          @invalid && "input-error"
        ]}
      >
        <%!-- Tags wrap onto as many lines as they take, the text box after
        them. A single pick holds one line: the text box lies over the
        selection, which is hidden only once something is typed to replace
        it, and a long selection is cut short rather than growing the box. --%>
        <div
          data-part="field"
          class={
            if @mode == :tags,
              do: "contents",
              else: "group/field grid min-w-0 flex-1 items-center"
          }
        >
          <%!-- Tags and the selection each sit in a box of their own, so
        adding one never moves the text box, which would lose its focus. --%>
          <span id={"#{@id}-held"} class="contents">
            <span
              :for={option <- if(@mode == :tags, do: @selection, else: [])}
              data-part="tag"
              data-value={option.value}
              data-new={option[:new] && "true"}
              data-unavailable={option[:unavailable] && "true"}
              class={[@classes.tag, option[:new] && "badge-outline"]}
            >
              <%= if @tag != [] do %>
                {render_slot(@tag, option)}
              <% else %>
                <span class="wrap-anywhere">{option.label}</span>
              <% end %>
              <span :if={option[:new]} class="text-xs opacity-80">{gettext("new")}</span>
              <button
                type="button"
                data-remove={option.value}
                class="cursor-pointer opacity-80 hover:opacity-100"
                aria-label={remove_name(option)}
              >
                <span aria-hidden="true">✕</span>
              </button>
            </span>
            <span
              :for={option <- if(@mode == :single, do: @selection, else: [])}
              id={@selection_id}
              data-part="selection"
              data-value={option.value}
              class={[
                "col-start-1 row-start-1 flex min-w-0 items-baseline gap-1 overflow-hidden",
                "group-has-[input:not(:placeholder-shown)]/field:invisible"
              ]}
            >
              <%= if @tag != [] do %>
                {render_slot(@tag, option)}
              <% else %>
                <%!-- Each part is cut short on its own, in its own direction, so
                a Latin name in a right-to-left page still shows its start. --%>
                <span data-part="label" dir="auto" class="min-w-0 truncate">{option.label}</span>
                <span
                  :if={option[:hint] not in [nil, ""]}
                  dir="auto"
                  class="min-w-0 max-w-1/2 shrink-0 truncate text-xs opacity-60"
                >
                  {option.hint}
                </span>
              <% end %>
            </span>
          </span>
          <input
            id={@field.id}
            type="text"
            role="combobox"
            autocomplete="off"
            data-part="input"
            class={[
              @classes.input,
              if(@mode == :tags, do: "grow basis-16", else: "col-start-1 row-start-1 w-full")
            ]}
            placeholder={placeholder(@mode, @selection, @placeholder)}
            aria-autocomplete="list"
            aria-expanded="false"
            aria-controls={@listbox_id}
            aria-labelledby={@label_id}
            aria-label={!@label_id && @aria_label}
            aria-describedby={described_by(@mode, @selection, @selection_id, @describedby)}
            aria-invalid={@invalid && "true"}
          />
        </div>
        <button
          :if={@mode == :single and @clearable and @selection != []}
          type="button"
          data-clear
          class="cursor-pointer opacity-60 hover:opacity-100 ms-auto"
          aria-label={gettext("Clear")}
        >
          <span aria-hidden="true">✕</span>
        </button>
      </div>

      <%= if @mode == :single do %>
        <input
          type="hidden"
          id={"#{@field.id}-value"}
          name={@field.name}
          value={Enum.map_join(@selection, & &1.value)}
          data-picker-value
        />
      <% else %>
        <input
          :if={@selection == []}
          type="hidden"
          id={"#{@field.id}_empty_selection"}
          name={"#{@field.form.name}[#{@field.field}_empty_selection]"}
          value=""
          data-picker-value
        />
        <input
          :for={{option, index} <- Enum.with_index(@selection)}
          type="hidden"
          id={"#{@field.id}-value-#{index}"}
          name={@field.name <> "[]"}
          value={option.value}
          data-picker-value
        />
      <% end %>

      <div id={"#{@id}-popup"} data-part="popup" class={["hidden", @classes.popup]}>
        <ul
          id={@listbox_id}
          role="listbox"
          aria-labelledby={@label_id}
          aria-label={!@label_id && @aria_label}
          aria-multiselectable={@mode == :tags && "true"}
        >
          <li
            :for={{option, index} <- Enum.with_index(@options)}
            id={"#{@id}-opt-#{index}"}
            role="option"
            aria-selected={to_string(MapSet.member?(@picked, option.value))}
            data-value={option.value}
            class={@classes.option}
          >
            <span aria-hidden="true" class="invisible group-aria-selected:visible">✓</span>
            <%= if @option != [] do %>
              {render_slot(@option, option)}
            <% else %>
              <span class="flex flex-col min-w-0">
                <span data-part="label" class="wrap-anywhere">{option.label}</span>
                <span :if={option[:hint]} data-part="hint" class="text-xs opacity-60 wrap-anywhere">
                  {option.hint}
                </span>
              </span>
            <% end %>
          </li>
          <li
            :if={@add}
            id={"#{@id}-opt-add"}
            role="option"
            aria-selected="false"
            data-value={@add}
            data-new
            class={@classes.option}
          >
            <span aria-hidden="true" class="invisible">✓</span>
            <span data-part="label" class="wrap-anywhere">{gettext("Add \"%{text}\"", text: @add)}</span>
          </li>
        </ul>
        <p
          :if={@searched? and not @searching? and @options == [] and !@add}
          class="px-3 py-2 text-sm opacity-70"
        >
          {gettext("No matches")}
        </p>
        <p :if={@more? and not @searching?} class="px-3 py-2 text-xs opacity-70">
          {gettext("Keep typing to narrow the list")}
        </p>
      </div>
      <div id={"#{@id}-status"} role="status" aria-live="polite" class="sr-only">{@status}</div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Picker">
        // The open list, the active option, the keys and the typing debounce
        // (`AshQuick.LiveView.Picker`). What the form posts is the server's.
        //
        // A pick, removal or clear is asked of it. Its reply names the count
        // of changes (`data-changes`) the patch drawing it carries, and once
        // the page shows that count, `input` is fired from the first hidden
        // input, so the form's `phx-change` runs with the field as its
        // target. The reply lands before its patch, which would post the old
        // inputs. Only what the hook asked for posts: a picker that rejoins
        // after a reconnect starts its count afresh, and the form recovery
        // has already posted what it holds.
        //
        // Each search carries a `seq`, which the server draws back as
        // `data-shown` with its results. While they differ the list is from
        // older text, so Enter waits, and picks the first new result once
        // it lands.
        //
        // Everything written to the page goes through `js()`, so it outlives
        // the server's patches, which always draw the list shut. The server
        // bumps `data-rev` when it draws new results, which is when the active
        // option goes back to the first.
        const DEBOUNCE = 200

        export default {
          mounted() {
            this.open = false
            this.activeId = null
            this.timer = null
            this.rev = this.el.dataset.rev
            this.awaiting = null
            this.seq = 0
            this.searching = false
            this.enterWaiting = false
            const typing = (e) => e.target === this.input()

            // The text box has no name: its own events are not the form's.
            this.el.addEventListener("input", (e) => {
              if (!typing(e)) return
              e.stopPropagation()
              this.typed()
            })
            this.el.addEventListener("change", (e) => { if (typing(e)) e.stopPropagation() })
            this.el.addEventListener("keydown", (e) => this.keydown(e))
            // A press in the list would blur the text box, and the blur close
            // the list before the click picks.
            this.el.addEventListener("mousedown", (e) => {
              if (e.target.closest("[data-part=popup]")) e.preventDefault()
            })
            this.el.addEventListener("click", (e) => this.clicked(e))
            this.el.addEventListener("focusout", (e) => {
              if (!this.el.contains(e.relatedTarget)) this.close()
            })
          },
          updated() {
            this.post()
            if (this.searching && Number(this.el.dataset.shown) === this.seq) this.searching = false
            if (this.el.dataset.rev === this.rev) return
            this.rev = this.el.dataset.rev
            if (this.open) {
              this.activate(this.options()[0] || null)
              this.reveal()
            }
            if (this.enterWaiting && !this.pending()) {
              this.enterWaiting = false
              const active = this.open && this.activeId && document.getElementById(this.activeId)
              if (active) this.pick(active)
            }
          },
          // Asks and searches made before the socket dropped get no answer
          // from the picker that rejoins.
          disconnected() {
            this.awaiting = null
            this.searching = false
            this.enterWaiting = false
          },
          destroyed() { clearTimeout(this.timer) },

          pending() { return this.timer !== null || this.searching },
          // Once posted, the server stops holding its selection against
          // redraws that left before the post.
          post() {
            if (this.awaiting === null || Number(this.el.dataset.changes) < this.awaiting) return
            const changes = Number(this.el.dataset.changes)
            this.awaiting = null
            const hidden = this.el.querySelector("input[data-picker-value]")
            if (hidden) hidden.dispatchEvent(new Event("input", {bubbles: true}))
            this.pushEventTo(this.el, "posted", {changes})
          },

          input() { return this.el.querySelector("[data-part=input]") },
          popup() { return this.el.querySelector("[data-part=popup]") },
          options() { return [...this.el.querySelectorAll("[role=option]")] },
          tags() { return [...this.el.querySelectorAll("[data-part=tag]")] },
          tagsMode() { return this.el.dataset.aqPicker === "tags" },

          show() {
            if (this.open) return
            this.open = true
            this.js().removeClass(this.popup(), "hidden")
            this.js().setAttribute(this.input(), "aria-expanded", "true")
            this.search(this.input().value)
          },
          close() {
            clearTimeout(this.timer)
            this.timer = null
            this.enterWaiting = false
            if (!this.open) return
            this.open = false
            this.activate(null)
            this.js().addClass(this.popup(), "hidden")
            this.js().setAttribute(this.input(), "aria-expanded", "false")
          },
          typed() {
            if (!this.open) return this.show()
            clearTimeout(this.timer)
            this.timer = setTimeout(() => this.search(this.input().value), DEBOUNCE)
          },
          search(text) {
            clearTimeout(this.timer)
            this.timer = null
            this.seq += 1
            this.searching = true
            this.pushEventTo(this.el, "search", {text, seq: this.seq})
          },
          // A list opened near a modal's bottom edge is cut off by the modal's
          // scrolling box: bring it into view.
          reveal() {
            const popup = this.popup()
            if (popup.scrollIntoView) popup.scrollIntoView({block: "nearest", inline: "nearest"})
          },
          activate(option) {
            const cls = this.el.dataset.activeClass.split(" ").filter(Boolean)
            const previous = this.activeId && document.getElementById(this.activeId)
            if (previous) this.js().removeClass(previous, cls)
            this.activeId = option ? option.id : null
            if (option) {
              this.js().addClass(option, cls)
              this.js().setAttribute(this.input(), "aria-activedescendant", option.id)
              option.scrollIntoView && option.scrollIntoView({block: "nearest", inline: "nearest"})
            } else {
              this.js().removeAttribute(this.input(), "aria-activedescendant")
            }
          },
          move(by) {
            const options = this.options()
            if (options.length === 0) return
            const at = options.findIndex((o) => o.id === this.activeId)
            const next = at === -1 ? (by > 0 ? 0 : options.length - 1) : (at + by + options.length) % options.length
            this.activate(options[next])
          },
          keydown(e) {
            // A key that ends an input method's composition is the IME's.
            if (e.target !== this.input() || e.isComposing || e.keyCode === 229) return
            const options = this.options()
            switch (e.key) {
              case "ArrowDown":
              case "ArrowUp":
                e.preventDefault()
                if (!this.open) this.show()
                else this.move(e.key === "ArrowDown" ? 1 : -1)
                break
              case "Home":
              case "End":
                if (!this.open || options.length === 0) return
                e.preventDefault()
                this.activate(e.key === "Home" ? options[0] : options[options.length - 1])
                break
              case "Enter":
                if (!this.open) return
                e.preventDefault()
                // The list is for older text: pick once the new one lands.
                if (this.pending()) {
                  if (this.timer) this.search(this.input().value)
                  this.enterWaiting = true
                  return
                }
                const active = this.activeId && document.getElementById(this.activeId)
                if (active) this.pick(active)
                break
              case "Escape":
                if (this.open) {
                  e.preventDefault()
                  e.stopPropagation()
                  this.close()
                } else if (this.input().value !== "") {
                  e.preventDefault()
                  e.stopPropagation()
                  this.input().value = ""
                }
                break
              case "Backspace":
                if (this.input().value !== "" || !this.tagsMode()) return
                const last = this.tags().pop()
                if (!last) return
                e.preventDefault()
                this.ask("remove", {value: last.dataset.value})
                break
              case "Tab":
                this.close()
                break
            }
          },
          clicked(e) {
            const remove = e.target.closest("[data-remove]")
            if (remove) return this.ask("remove", {value: remove.dataset.remove}, true)
            if (e.target.closest("[data-clear]")) return this.ask("clear", {}, true)
            const option = e.target.closest("[role=option]")
            if (option) return this.pick(option)
            if (e.target.closest("[data-part=box]")) {
              this.input().focus()
              this.show()
            }
          },
          pick(option) {
            const params = {value: option.dataset.value, new: option.hasAttribute("data-new")}
            this.ask("pick", params)
            this.input().value = ""
            if (this.tagsMode()) this.search("")
            else this.close()
          },
          ask(event, params, refocus) {
            this.pushEventTo(this.el, event, params, (reply) => {
              if (!reply || !reply.changed) return
              this.awaiting = reply.changes
              // In case the patch was applied first.
              this.post()
            })
            if (refocus) this.input().focus()
          }
        }
      </script>
    </div>
    """
  end

  # Held, a single picker's text box keeps a blank placeholder, so the
  # selection under it can tell typed text (`:placeholder-shown` no longer
  # matching) from none.
  defp placeholder(:single, [_held], _placeholder), do: " "
  defp placeholder(_mode, [], placeholder), do: placeholder
  defp placeholder(_mode, _held, _placeholder), do: nil

  # A tag's ✕ is named for its label, and its hint when it has one, so two
  # sharing a label are named apart.
  defp remove_name(%{label: label, hint: hint}) when hint not in [nil, ""],
    do: gettext("Remove %{label} (%{hint})", label: label, hint: hint)

  defp remove_name(%{label: label}), do: gettext("Remove %{label}", label: label)

  defp described_by(mode, selection, selection_id, ids) do
    ids = if mode == :single and selection != [], do: [selection_id | List.wrap(ids)], else: ids

    case ids |> List.wrap() |> Enum.reject(&(&1 in [nil, false, ""])) do
      [] -> nil
      ids -> Enum.join(ids, " ")
    end
  end

  # The typed text, as the row that adds it, when it is new: it matches no
  # option offered and nothing already picked.
  defp add_text(%{create: create, query: query} = assigns)
       when create not in [false, nil] and is_binary(query) do
    taken = Enum.flat_map(assigns.options ++ assigns.selection, &[&1.value, &1.label])

    same? =
      if assigns.create_match == :any_case, do: &(fold(&1) == fold(query)), else: &(&1 == query)

    unless Enum.any?(taken, &(is_binary(&1) and same?.(&1))), do: query
  end

  defp add_text(_assigns), do: nil

  defp fold(text), do: String.downcase(text)

  defp status(%{searching?: true}), do: gettext("Searching…")
  defp status(%{searched?: false}), do: ""

  # With nothing found, an Add row is still an option to land on, so it is
  # announced rather than "no results".
  defp status(%{options: []} = assigns) do
    case add_text(assigns) do
      nil -> gettext("No matches")
      text -> gettext("No matches. You can add \"%{text}\".", text: text)
    end
  end

  defp status(%{options: options}),
    do: ngettext("%{count} result", "%{count} results", length(options))
end
