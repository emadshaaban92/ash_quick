defmodule AshQuick.LiveView.Components.RecordOption do
  @moduledoc false
  # How a relationship dropdown draws a record built by
  # `AshQuick.LiveView.Utils.to_option/2`: its name, and its display hint
  # beside it, so two records sharing a name can be told apart both in the
  # open list and among the picked tags. The parts are marked so a test can
  # read the name on its own.
  #
  # An option LiveSelect restored after a reconnect has its `:label` alone,
  # which already reads "Name (hint)", so it is drawn as that.
  use Phoenix.Component

  attr :option, :map, required: true

  def record_option(assigns) do
    ~H"""
    <span class="flex flex-col min-w-0">
      <span data-part="label">{@option[:name] || @option.label}</span>
      <span
        :if={@option[:name] && @option[:hint]}
        data-part="hint"
        class="text-xs opacity-60 truncate"
      >
        {@option.hint}
      </span>
    </span>
    """
  end

  attr :option, :map, required: true

  # A tag is one line inside a badge, so the hint follows the name.
  def record_tag(assigns) do
    ~H"""
    <span data-part="label">{@option[:name] || @option.label}</span>
    <span :if={@option[:name] && @option[:hint]} data-part="hint" class="opacity-70">
      {@option.hint}
    </span>
    """
  end
end
