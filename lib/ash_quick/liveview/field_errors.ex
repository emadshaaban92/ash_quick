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

  @doc """
  `for_field/2` for an attachment, whose value posts from a hidden input.
  LiveView never marks a hidden input unused, so a blank one posts `""` with
  every change event and `used_input?/1` would count it as a touch, showing
  the error on the first keystroke anywhere in the form. Only a field holding
  something the person put there counts as used.
  """
  def for_hidden_input(%FormField{form: form, field: name} = field) do
    used? =
      Phoenix.Component.used_input?(field) and not blank?(Map.get(form.params, to_string(name)))

    for_field(field, used?)
  end

  @doc """
  Whether the person has used a LiveSelect widget, given what it was told on
  the render before (`nil` on the first). A select widget keeps the result in
  its own assigns and passes it to `for_select/2`.

  Its value posts from a hidden input too, but unlike an attachment's it can
  be cleared, and a cleared select posts the same blank as one never touched.
  So the widget remembers: it counts as used once it has posted a value, or
  once a change event came while it started with one, as clearing a stored
  value does. A form with no params yet starts over.
  """
  def select_touch(_touch, %FormField{form: %{params: params}} = field)
      when map_size(params) == 0,
      do: %{started_blank?: blank?(field.value), used?: false}

  def select_touch(nil, %FormField{} = field),
    do: select_touch(%{started_blank?: blank?(field.value), used?: false}, field)

  def select_touch(%{used?: true} = touch, _field), do: touch

  def select_touch(%{started_blank?: started_blank?} = touch, %FormField{} = field) do
    posted = Map.get(field.form.params, to_string(field.field))
    %{touch | used?: not started_blank? or not blank?(posted)}
  end

  @doc "`for_field/2` for a LiveSelect widget, with what `select_touch/2` made of it."
  def for_select(%FormField{} = field, %{used?: used?}), do: for_field(field, used?)

  defp blank?(value), do: value in [nil, "", []]

  # An `AshPhoenix.Form` marks itself and every sub-form submitted on the first
  # submit, so a nested field sees it too.
  defp submitted?(%Phoenix.HTML.Form{source: %AshPhoenix.Form{submitted_once?: true}}), do: true
  defp submitted?(_form), do: false
end
