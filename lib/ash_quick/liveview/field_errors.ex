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

  use Phoenix.Component

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
  something the person put there counts as used, and an array emptied by its
  ✕ (`[]`) does.
  """
  def for_hidden_input(%FormField{form: form, field: name} = field) do
    used? =
      Phoenix.Component.used_input?(field) and
        Map.get(form.params, to_string(name)) not in [nil, ""]

    for_field(field, used?)
  end

  @doc """
  `for_field/2` for a LiveSelect widget, which must also render
  `used_marker/1` for the field.

  Its value posts from a hidden input too, and a cleared select posts the same
  blank as one never touched, so the value cannot say whether it was used. The
  change event can: LiveSelect fires it from the field's own hidden input, so
  its `_target` names the field. The form marks that field in its params
  (`mark_used/2`), and `used_marker/1` keeps the mark on the page. Each post
  carries it from then on, and so does the post that recovers the form after a
  reconnect. A field another input's change merely posts along is not marked,
  however long it has held a value.
  """
  def for_select(%FormField{form: form, field: name} = field),
    do: for_field(field, Map.has_key?(form.params, used_key(name)))

  @doc """
  Marks the field the change event's `_target` names as used, in the form
  params it posted (`params["form"]` for a QuickView). A multi-select emptied
  of its last pick fires from its `<name>_empty_selection` input, which marks
  `<name>`. Anything else, such as a target in no posted form, is left alone.
  """
  def mark_used(params, [_form_name | path]) when is_map(params) do
    case Enum.split(path, -1) do
      {parents, [name]} when is_binary(name) and name != "" ->
        put_used(params, parents, used_key(String.replace_suffix(name, "_empty_selection", "")))

      _no_field ->
        params
    end
  end

  def mark_used(params, _target), do: params

  defp put_used(params, [], key), do: Map.put(params, key, "true")

  defp put_used(params, [parent | rest], key) do
    case params do
      %{^parent => %{} = nested} -> Map.put(params, parent, put_used(nested, rest, key))
      _not_posted -> params
    end
  end

  @doc """
  The hidden input that keeps `field`'s used mark on the page, rendered by any
  widget that reads its errors through `for_select/1`. Renders nothing until
  the field is marked.
  """
  def used_marker(%{field: %FormField{form: form, field: name}} = assigns) do
    assigns =
      Phoenix.Component.assign(assigns,
        name: Phoenix.HTML.Form.input_name(form, used_key(name)),
        used?: Map.has_key?(form.params, used_key(name))
      )

    ~H"""
    <input :if={@used?} type="hidden" name={@name} value="true" />
    """
  end

  defp used_key(name), do: "_used_#{name}"

  # An `AshPhoenix.Form` marks itself and every sub-form submitted on the first
  # submit, so a nested field sees it too.
  defp submitted?(%Phoenix.HTML.Form{source: %AshPhoenix.Form{submitted_once?: true}}), do: true
  defp submitted?(_form), do: false
end
