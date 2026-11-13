defmodule AshQuick.LiveView.Components.MapValue do
  @moduledoc false
  # A stored map (`AshQuick.LiveView.StoredMap`) as a list cell or a details
  # page shows it. The details view is `<details>` all the way down, so it
  # opens and closes with no JS at all; only Copy needs a hook.
  use Phoenix.Component
  use Gettext, backend: AshQuick.Gettext

  alias AshQuick.LiveView.StoredMap

  # A string longer than this shows cut, with a toggle for the rest.
  @long_string 200

  # A nested branch with this many leaves or fewer, and nothing nested in it,
  # starts open: an audit row's `from`/`to` pair reads without a click.
  @open_leaves 5

  @title_length 300

  attr :value, :any, required: true

  def cell(assigns) do
    assigns =
      assigns
      |> assign(:summary, StoredMap.summary(assigns.value))
      |> assign(:title, StoredMap.cut(StoredMap.json(assigns.value), @title_length))

    ~H"""
    <span class="inline-flex max-w-xs items-baseline gap-1 align-bottom" data-stored-map="cell">
      <%= case @summary do %>
        <% :empty -> %>
          <span class="text-base-content/50">{gettext("Empty")}</span>
        <% {:items, count} -> %>
          <span>{ngettext("%{count} item", "%{count} items", count)}</span>
        <% {:pairs, pairs, more} -> %>
          <span class="min-w-0 truncate" dir="auto" title={@title}>
            <span :for={{{key, value}, i} <- Enum.with_index(pairs)}><span
              :if={i != 0}
              class="text-base-content/40"
            > · </span><span class="text-base-content/60">{key}:{" "}</span><.short value={value} /></span>
          </span>
          <span :if={more > 0} class="shrink-0 text-base-content/60">
            {gettext("+%{count}", count: more)}
          </span>
      <% end %>
    </span>
    """
  end

  attr :value, :any, required: true

  defp short(%{value: {:scalar, value}} = assigns) do
    assigns = assign(assigns, :value, value)

    ~H"""
    <.inline_value value={@value} />
    """
  end

  defp short(%{value: {:inline, pairs}} = assigns) do
    assigns = assign(assigns, :pairs, Enum.with_index(pairs))

    ~H"""
    <span>&lbrace;<span :for={{{key, value}, i} <- @pairs}>{if i != 0, do: ", "}{key}:{" "}<.short value={value} /></span>&rbrace;</span>
    """
  end

  defp short(%{value: {:map, count}} = assigns) do
    assigns = assign(assigns, :count, count)

    ~H"""
    <span class="text-base-content/60">{ngettext("{%{count} key}", "{%{count} keys}", @count)}</span>
    """
  end

  defp short(%{value: {:list, count}} = assigns) do
    assigns = assign(assigns, :count, count)

    ~H"""
    <span class="text-base-content/60">{ngettext("[%{count} item]", "[%{count} items]", @count)}</span>
    """
  end

  attr :id, :string,
    default: nil,
    doc: "the prefix of the view's own ids; with none, Raw JSON has no Copy button"

  attr :value, :any, required: true

  def details(assigns) do
    {nodes, omitted} = StoredMap.tree(assigns.value)

    assigns =
      assigns
      |> assign(:nodes, nodes)
      |> assign(:omitted, omitted)
      |> assign(:raw, StoredMap.json(assigns.value, pretty: true))

    ~H"""
    <div class="w-full min-w-0 space-y-2 text-sm" data-stored-map="details">
      <span :if={@nodes == [] and @omitted == 0} class="text-base-content/50">
        {gettext("Empty")}
      </span>
      <.tree :if={@nodes != [] or @omitted > 0} nodes={@nodes} omitted={@omitted} />
      <details :if={@value not in [%{}, []]} class="group">
        <summary class="cursor-pointer text-xs text-base-content/60 select-none">
          {gettext("Raw JSON")}
        </summary>
        <div class="relative mt-1">
          <pre
            id={@id && "#{@id}-raw"}
            dir="ltr"
            class="max-h-80 overflow-auto rounded-box bg-base-200 p-3 pe-16 text-start text-xs"
          >{@raw}</pre>
          <button
            :if={@id}
            id={"#{@id}-copy"}
            type="button"
            phx-hook=".CopyText"
            data-copy-from={"#{@id}-raw"}
            class="btn btn-xs absolute top-2 end-2"
          >
            <span>{gettext("Copy")}</span>
            <span class="hidden" role="status">{gettext("Copied")}</span>
          </button>
        </div>
      </details>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyText">
      // Copies the text of the element `data-copy-from` names, and says so
      // for a moment on the button.
      export default {
        mounted() {
          this.el.addEventListener("click", () => {
            const source = document.getElementById(this.el.dataset.copyFrom)
            if (!source || !navigator.clipboard) return
            navigator.clipboard.writeText(source.textContent).then(() => {
              const [copy, copied] = this.el.children
              copy.classList.add("hidden")
              copied.classList.remove("hidden")
              clearTimeout(this.timer)
              this.timer = setTimeout(() => {
                copy.classList.remove("hidden")
                copied.classList.add("hidden")
              }, 1500)
            })
          })
        },
        destroyed() {
          clearTimeout(this.timer)
        }
      }
    </script>
    """
  end

  attr :nodes, :list, required: true
  attr :omitted, :integer, required: true

  defp tree(assigns) do
    ~H"""
    <ul class="space-y-0.5">
      <li :for={node <- @nodes} data-key={node.key}>
        <.tree_node node={node} />
      </li>
      <li :if={@omitted > 0} class="text-base-content/50 italic">
        {ngettext(
          "%{count} more not shown; see Raw JSON",
          "%{count} more not shown; see Raw JSON",
          @omitted
        )}
      </li>
    </ul>
    """
  end

  attr :node, :map, required: true

  defp tree_node(%{node: %{kind: :scalar}} = assigns) do
    ~H"""
    <.key key={@node.key} /> <.leaf value={@node.value} />
    """
  end

  defp tree_node(assigns) do
    assigns = assign(assigns, :open?, starts_open?(assigns.node))

    ~H"""
    <details open={@open?}>
      <summary class="cursor-pointer">
        <.key key={@node.key} />
        <span class="text-base-content/50">{size(@node)}</span>
      </summary>
      <div class="ms-1 border-s border-base-300 ps-3">
        <.tree nodes={@node.children} omitted={@node.omitted} />
      </div>
    </details>
    """
  end

  attr :key, :any, required: true

  defp key(%{key: key} = assigns) when is_integer(key) do
    ~H"""
    <span class="text-base-content/60 tabular-nums">{@key}.</span>
    """
  end

  defp key(assigns) do
    ~H"""
    <span class="font-medium" dir="auto">{@key}</span><span class="text-base-content/50">:</span>
    """
  end

  attr :value, :any, required: true

  defp leaf(%{value: value} = assigns) when is_binary(value) do
    cond do
      StoredMap.redacted?(value) ->
        ~H"""
        <.redacted />
        """

      String.length(value) > @long_string ->
        assigns = assign(assigns, :start, String.slice(value, 0, @long_string))

        ~H"""
        <details class="group inline">
          <summary class="inline cursor-pointer list-none">
            <span class="whitespace-pre-wrap break-words group-open:hidden" dir="auto">{@start}…</span>
            <span class="link text-xs group-open:hidden">{gettext("Show all")}</span>
            <span class="link text-xs hidden group-open:inline">{gettext("Show less")}</span>
          </summary>
          <span class="whitespace-pre-wrap break-words" dir="auto">{@value}</span>
        </details>
        """

      true ->
        ~H"""
        <span class="whitespace-pre-wrap break-words" dir="auto">{@value}</span>
        """
    end
  end

  defp leaf(assigns), do: inline_value(assigns)

  attr :value, :any, required: true

  defp inline_value(%{value: nil} = assigns) do
    ~H"""
    <span class="text-base-content/50 italic">{gettext("empty")}</span>
    """
  end

  defp inline_value(%{value: value} = assigns) when is_boolean(value) do
    ~H"""
    <span>{if @value, do: gettext("Yes"), else: gettext("No")}</span>
    """
  end

  defp inline_value(%{value: value} = assigns) when is_binary(value) do
    if StoredMap.redacted?(value) do
      ~H"""
      <.redacted />
      """
    else
      ~H"""
      <span dir="auto">{@value}</span>
      """
    end
  end

  defp inline_value(%{value: value} = assigns) when is_number(value) do
    ~H"""
    <span class="tabular-nums">{@value}</span>
    """
  end

  # Anything else a map built in memory may hold, such as a date or an atom.
  defp inline_value(assigns) do
    assigns = assign(assigns, :text, text(assigns.value))

    ~H"""
    <span dir="auto">{@text}</span>
    """
  end

  defp redacted(assigns) do
    assigns = assign(assigns, mask: AshQuick.Info.mask(nil), label: gettext("Redacted"))

    # No whitespace inside: the mask sits right before a `,` or `}`.
    ~H"""
    <span class="text-base-content/50" title={@label}>{@mask}<span class="sr-only">{@label}</span></span>
    """
  end

  defp text(value) do
    if String.Chars.impl_for(value), do: to_string(value), else: inspect(value)
  end

  defp starts_open?(%{children: children, omitted: 0}) do
    length(children) <= @open_leaves and Enum.all?(children, &(&1.kind == :scalar))
  end

  defp starts_open?(_node), do: false

  defp size(%{kind: :map, size: size}), do: ngettext("%{count} key", "%{count} keys", size)
  defp size(%{kind: :list, size: size}), do: ngettext("%{count} item", "%{count} items", size)
end
