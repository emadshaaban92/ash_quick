defmodule AshQuick.LiveView.Components.RecordOption do
  @moduledoc false
  # How a relationship dropdown draws a record built by
  # `AshQuick.LiveView.Utils.to_option/2`: its name, and its display hint on a
  # line of its own under it, so two records sharing a name can be told apart
  # both in the open list and among the picked tags. The parts are marked so a
  # test can read the name on its own.
  #
  # A hint is often one unbroken word (an email), so it wraps anywhere rather
  # than overflowing a narrow column or squeezing the name beside it.
  #
  # An option LiveSelect restored after a reconnect has its `:label` alone,
  # which already reads "Name (hint)", so it is drawn as that.
  use Phoenix.Component

  attr :option, :map, required: true

  def record_option(assigns) do
    ~H"""
    <.parts option={@option} hint_class="opacity-60" />
    """
  end

  attr :option, :map, required: true

  # On the badge's own colour the hint needs more contrast than in the list.
  def record_tag(assigns) do
    ~H"""
    <.parts option={@option} hint_class="opacity-80" />
    """
  end

  attr :option, :map, required: true
  attr :hint_class, :string, required: true

  defp parts(assigns) do
    ~H"""
    <span class="flex flex-col min-w-0 text-left">
      <span data-part="label" class="wrap-anywhere">{@option[:name] || @option.label}</span>
      <span
        :if={@option[:name] && @option[:hint]}
        data-part="hint"
        class={["text-xs wrap-anywhere", @hint_class]}
      >
        {@option.hint}
      </span>
    </span>
    """
  end
end
