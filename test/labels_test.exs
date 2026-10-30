defmodule AshQuick.LabelsTest do
  @moduledoc """
  A label is looked up in the host's `:gettext` backend, in the `ash_quick`
  domain and that backend's locale, and anything that is not a string is drawn
  as it is.

  Not async: the backend is application config, read on every call.
  """
  use ExUnit.Case, async: false

  import Phoenix.Component, only: [sigil_H: 2]

  alias AshQuick.Labels

  setup do
    original = Application.get_env(:ash_quick, :gettext)
    Application.put_env(:ash_quick, :gettext, AshQuick.Test.LabelGettext)
    on_exit(fn -> Application.put_env(:ash_quick, :gettext, original) end)

    Gettext.put_locale(AshQuick.Test.LabelGettext, "ar")
    :ok
  end

  test "a string is translated, and a name is humanized first" do
    assert Labels.translate("Price") == "السعر"
    assert Labels.name(:shelf_life) == "مدة الصلاحية"
    assert Labels.translate("Unlisted") == "Unlisted"
  end

  # A `label:` option is stored unchecked, so markup that rendered before
  # labels were translated still renders rather than taking the LiveView down.
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

  test "in the host's default locale, a label is drawn as it is" do
    Gettext.put_locale(AshQuick.Test.LabelGettext, "en")

    assert Labels.translate("Price") == "Price"
  end

  # A label is text, not a message with bindings.
  test "a label holding a binding's syntax is drawn as written" do
    assert Labels.translate("Rate (%{unit})") == "Rate (%{unit})"

    Application.delete_env(:ash_quick, :gettext)
    assert Labels.translate("Rate (%{unit})") == "Rate (%{unit})"
  end

  test "with no backend, a label is drawn as it is" do
    Application.delete_env(:ash_quick, :gettext)

    assert Labels.translate("Price") == "Price"
    assert Labels.name(:shelf_life) == "Shelf Life"
  end
end
