defmodule AshQuick.LiveView.FieldErrors do
  @moduledoc """
  Which of a form field's errors to render, and when.

  A field's errors show once the person has used the input, or once the form
  has been submitted. `Phoenix.Component.used_input?/1` alone misses the
  second case whenever a field is absent from the params a refused save was
  made with: a list of nested forms with none added posts nothing under its
  name, and an attachment with nothing picked is left out on purpose. Such a
  field reads as untouched, so the error the save failed on never showed.

  Kept out of `AshQuick.Components` on purpose: that module is imported whole
  into every QuickView, where a public function would collide with any host
  helper of the same name.
  """

  alias Phoenix.HTML.FormField

  @doc """
  The errors to render beside `field`, translated with
  `AshQuick.Components.translate_error/1`, or `[]` while they would only be
  noise.

  `used?` is what counts as using the input, for a widget whose posted value
  says more than `used_input?/1` can (an attachment's blank hidden input is not
  a touch). `for_field/1` takes `used_input?/1`.
  """
  def for_field(%FormField{} = field),
    do: for_field(field, Phoenix.Component.used_input?(field))

  def for_field(%FormField{} = field, used?) do
    if used? or submitted?(field.form),
      do: Enum.map(field.errors, &AshQuick.Components.translate_error/1),
      else: []
  end

  # An `AshPhoenix.Form` marks itself and every sub-form submitted on the first
  # submit, so a nested field sees it too.
  defp submitted?(%Phoenix.HTML.Form{source: %AshPhoenix.Form{submitted_once?: true}}), do: true
  defp submitted?(_form), do: false
end
