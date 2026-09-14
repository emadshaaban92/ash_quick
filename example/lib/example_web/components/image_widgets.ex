defmodule ExampleWeb.ImageWidgets do
  @moduledoc """
  QuickView list/details widgets for attachment fields.

  They render through `AshQuick.Components.attachment_img/1` — a real HEEx
  component, which escapes its attributes — rather than through the generic
  field renderer, and that is also what gives them the library's
  processing/rejected placeholders instead of bare text.

  Declare one alongside the field:

      fields: [{:image, widget: &ExampleWeb.ImageWidgets.image/1}]
  """
  use Phoenix.Component

  import AshQuick.Components, only: [attachment_img: 1]

  @doc "Renders an attachment as a thumbnail — one, a list of them, or nothing."
  attr :value, :any, required: true

  def image(%{value: nil} = assigns) do
    ~H"""
    <span></span>
    """
  end

  def image(%{value: value} = assigns) when is_list(value) do
    assigns = assign(assigns, :states, states(Enum.map(value, & &1.attachment)))

    ~H"""
    <div class="flex flex-wrap gap-2">
      <.attachment_img
        :for={image <- @value}
        value={image.attachment}
        alt={image.alt || ""}
        states={@states}
        class="max-w-36"
      />
    </div>
    """
  end

  def image(assigns) do
    assigns = assign(assigns, :states, states([assigns.value]))

    ~H"""
    <.attachment_img value={@value} alt="" states={@states} class="max-w-36" />
    """
  end

  # Passed explicitly rather than left to `attachment_img/1`'s default, which
  # reads an absent key as `:ready` — right for a caller that prefetched the
  # page's states, wrong here, where skipping the lookup would point an `<img>`
  # at an object the host is still holding.
  defp states(attachments), do: AshQuick.Storage.states_for(attachments)
end
