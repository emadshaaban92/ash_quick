defmodule AshQuick.LabelsTest do
  @moduledoc """
  A label is handed to the host's `:label_translator`, and anything that is
  not a string is drawn as it is.

  Not async: the translator is application config, read on every call.
  """
  use ExUnit.Case, async: false

  import Phoenix.Component, only: [sigil_H: 2]

  alias AshQuick.Labels

  defmodule Translator do
    @moduledoc false
    def translate_label("Price"), do: "السعر"
    def translate_label("Shelf Life"), do: "مدة الصلاحية"
    def translate_label(label), do: label
  end

  setup do
    original = Application.get_env(:ash_quick, :label_translator)
    Application.put_env(:ash_quick, :label_translator, {Translator, :translate_label})

    on_exit(fn ->
      if original,
        do: Application.put_env(:ash_quick, :label_translator, original),
        else: Application.delete_env(:ash_quick, :label_translator)
    end)
  end

  test "a string goes through the translator, and a name is humanized first" do
    assert Labels.translate("Price") == "السعر"
    assert Labels.name(:shelf_life) == "مدة الصلاحية"
    assert Labels.translate("Unlisted") == "Unlisted"
  end

  # A `label:` option is stored unchecked, so markup that rendered before a
  # translator existed still renders rather than taking the LiveView down.
  test "anything but a string is drawn as it is" do
    assigns = %{}
    markup = ~H"<b>Price</b>"

    assert Labels.translate(markup) == markup
    assert Labels.translate(nil) == nil
    assert Labels.translate(:price) == :price
  end

  test "a field is labelled by its label option, or its name" do
    assert Labels.field(:price) == "السعر"
    assert Labels.field({:cost, "Price"}) == "السعر"
    assert Labels.field({:shelf_life, widget: nil}) == "مدة الصلاحية"
    assert Labels.field([:price]) == "السعر"
  end

  test "with no translator, a label is drawn as it is" do
    Application.delete_env(:ash_quick, :label_translator)

    assert Labels.translate("Price") == "Price"
    assert Labels.name(:shelf_life) == "Shelf Life"
  end
end
