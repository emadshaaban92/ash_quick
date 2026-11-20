defmodule AshQuick.LiveView.Components.FieldHelp do
  @moduledoc false
  # The help text under a form input (`AshQuick.Labels.help/2`), and the
  # `aria-describedby` that has a screen reader read it, and the input's
  # errors, with the input. Kept out of `AshQuick.Components`, which a host's
  # QuickView imports whole.
  use Phoenix.Component

  attr :id, :string, default: nil, doc: "the input's id; the help's is derived from it"
  attr :text, :string, default: nil
  attr :class, :any, default: "mt-1", doc: "its margins, `mt-1` by default"

  def help(assigns) do
    ~H"""
    <p :if={@text} id={id(@id)} class={["text-sm text-base-content/70", @class]} data-field-help>
      {@text}
    </p>
    """
  end

  @doc false
  def id(nil), do: nil
  def id(input_id), do: "#{input_id}-help"

  @doc false
  # An input drawn with no id has nothing to point at: it is only marked
  # invalid. The help is read before the errors, as it sits above them.
  def describe_attrs(input_id, help, errors) do
    described_by =
      if input_id,
        do:
          Enum.reject(
            [help && id(input_id), errors != [] && "#{input_id}-errors"],
            &(&1 in [nil, false])
          )

    invalid = if errors != [], do: ["aria-invalid": "true"], else: []

    case described_by do
      [_ | _] -> invalid ++ ["aria-describedby": Enum.join(described_by, " ")]
      _none -> invalid
    end
  end
end
