defmodule AshQuick.LiveView.ActionErrorsTranslatorTest do
  @moduledoc """
  Ash's messages in a flash go through the host's `:error_translator`, as they
  do next to an input, and the field named in front of one is a label, looked
  up in its `:gettext` backend.

  Not async: the translator and the backend are application config, read on
  every call.
  """
  use ExUnit.Case, async: false

  alias AshQuick.LiveView.ActionErrors

  defmodule Translator do
    @moduledoc false
    # A catalogue of one message, so a test can tell a translated message from
    # an interpolated one. The vars are handed back so a test can see them.
    def translate_error({"is required", _vars}), do: "est obligatoire"
    def translate_error({"must match %{match}", vars}), do: "doit correspondre à #{vars[:match]}"

    def translate_error({"Transfer not found for tracking number: %{number}", vars}),
      do: "لم يتم العثور على نقل برقم التتبع: #{vars[:number]}"

    def translate_error({"Only a manager may close a store.", []}),
      do: "Seul un responsable peut fermer un magasin."

    def translate_error({msg, vars}) do
      send(self(), {:translated, msg, vars})
      ActionErrors.interpolate(msg, vars)
    end
  end

  # Its French catalogue holds one label, so the other tests' fields are still
  # drawn in English.
  setup do
    put_config(:error_translator, {Translator, :translate_error})
    put_config(:gettext, AshQuick.Test.LabelGettext)
    Gettext.put_locale(AshQuick.Test.LabelGettext, "fr")
    :ok
  end

  defp put_config(key, value) do
    original = Application.get_env(:ash_quick, key)
    Application.put_env(:ash_quick, key, value)

    on_exit(fn ->
      if original,
        do: Application.put_env(:ash_quick, key, original),
        else: Application.delete_env(:ash_quick, key)
    end)
  end

  test "translates a message before the field name goes in front of it" do
    error =
      Ash.Error.Invalid.exception(
        errors: [Ash.Error.Changes.Required.exception(field: :name, type: :attribute)]
      )

    assert ActionErrors.user_facing_message(error) == "Name: est obligatoire"
  end

  test "names the field in front in the reader's language" do
    error =
      Ash.Error.Invalid.exception(
        errors: [Ash.Error.Changes.Required.exception(field: :sku, type: :attribute)]
      )

    assert ActionErrors.user_facing_message(error) == "Référence: est obligatoire"
  end

  # Arabic has no capital letters, so a whole sentence translated into it reads
  # like any fragment: the field goes in front all the same, set off.
  test "puts the field in front of a sentence translated into an uncased script" do
    error =
      Ash.Error.Invalid.exception(
        errors: [
          Ash.Error.Changes.InvalidAttribute.exception(
            field: :tracking_number,
            message: "Transfer not found for tracking number: %{number}",
            vars: [number: "TN123"]
          )
        ]
      )

    assert ActionErrors.user_facing_message(error) ==
             "Tracking Number: لم يتم العثور على نقل برقم التتبع: TN123"
  end

  # A policy's `error_message` is a msgid like Ash's own.
  test "translates the refusing policy's message" do
    error =
      Ash.Error.Forbidden.exception(
        errors: [
          Ash.Error.Forbidden.Policy.exception(
            custom_message: "Only a manager may close a store."
          )
        ]
      )

    assert ActionErrors.user_facing_message(error) ==
             "Seul un responsable peut fermer un magasin."
  end

  test "translates a message that names no field" do
    error =
      Ash.Error.Invalid.exception(
        errors: [Ash.Error.Changes.InvalidChanges.exception(message: "is required")]
      )

    assert ActionErrors.user_facing_message(error) == "est obligatoire"
  end

  # A translator interpolating a Regex would raise; it gets the regex rendered.
  test "hands the translator a var with no String.Chars already rendered" do
    assert ActionErrors.translate("must match %{match}", match: ~r/^\d+$/) ==
             ~S"doit correspondre à ~r/^\d+$/"
  end

  # The integer a translator picks a plural form by stays an integer.
  test "leaves a var that renders as it is" do
    ActionErrors.translate("at least %{count} characters", count: 3, min: :three)

    assert_received {:translated, "at least %{count} characters", [count: 3, min: :three]}
  end

  test "takes a map of vars as a keyword list" do
    ActionErrors.translate("one of %{values}", %{values: "a, b"})

    assert_received {:translated, "one of %{values}", [values: "a, b"]}
  end

  test "forms translate through the same function" do
    assert AshQuick.Components.translate_error({"is required", []}) == "est obligatoire"
  end
end
