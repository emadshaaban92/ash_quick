defmodule AshQuick.LiveView.FormSaveErrors do
  @moduledoc false
  # What a refused save says, and where: under an input the page draws, or
  # flashed, named by the sub-form it is about.
  import Phoenix.LiveView, only: [put_flash: 3]
  alias AshQuick.Labels
  alias AshQuick.LiveView.ActionErrors
  alias AshQuick.LiveView.Utils

  @doc false
  def describe_failed_save(form) do
    case input_errors(form) do
      [] ->
        modules =
          form
          |> raw_errors()
          |> Enum.map_join(", ", fn
            %module{} -> inspect(module)
            _not_a_struct -> "an unstructured error"
          end)

        "no field errors, the action returned [#{modules}]"

      errors ->
        "errors on fields #{errors |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.join(", ")}"
    end
  end

  # Every input error on the form and its sub-forms, each named by its field
  # under the path of the form it is on (`items[0].status`). An error a
  # sub-form's changeset refuses is filed on that sub-form, never on the root,
  # so the root's own errors miss it: AshPhoenix walks the whole tree for them.
  @doc false
  def input_errors(form) do
    form
    |> AshPhoenix.Form.errors(for_path: :all)
    |> Enum.flat_map(fn {path, errors} ->
      Enum.map(errors, fn {field, message} -> {field_path(path, field), message} end)
    end)
  end

  # An error AshPhoenix keeps on the root at a sub-form's path is also copied
  # onto that sub-form, so the same error can be here twice. Each is worded
  # the same either way, and every message below says a sentence once.
  defp raw_errors(form),
    do: form |> AshPhoenix.Form.raw_errors(for_path: :all) |> Map.values() |> List.flatten()

  defp field_path(path, field) do
    path
    |> Enum.reduce("", fn
      index, acc when is_integer(index) -> acc <> "[#{index}]"
      name, "" -> "#{name}"
      name, acc -> acc <> ".#{name}"
    end)
    |> case do
      "" -> field
      prefix -> "#{prefix}.#{field}"
    end
  end

  # The root holds what the action returned; a sub-form refused before the
  # action ran holds its own refusal. No error anywhere explains nothing, so it
  # is not put down to the policy either.
  @doc false
  def failed_save_message(form) do
    case raw_errors(form) do
      [] ->
        ActionErrors.generic_message()

      errors ->
        errors |> Ash.Error.to_error_class() |> ActionErrors.user_facing_message(form.resource)
    end
  end

  # An error on a field the form renders an input for shows under that input,
  # and only there. Anything else has nowhere on the page to show: an error
  # about the record as a whole (`:_form`, the key `AshPhoenix.FormData.Error`
  # files those under), or one on a field the action sets without offering it
  # (a change, an attribute it does not accept, a read-only field). Those
  # are flashed, worded as `ActionErrors` words a field error, so the submit
  # never fails without saying why. Where an error shows depends on where it
  # belongs, not on how many there are. A sub-form's errors are held to the
  # inputs the page draws for it, and each flashed one says which item it is
  # about: "Items 2 › Note: is hidden". A field the form state hides or
  # disables draws no input to show an error under, so its errors are flashed
  # too, on the root form or a sub-form, and so are those of a sub-form under
  # it.
  @doc false
  def flash_unplaced_errors(socket, form, scope, state \\ nil) do
    form
    |> AshPhoenix.Form.raw_errors(for_path: :all)
    # A map past 32 keys iterates in hash order; the page reads top to bottom.
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {path, errors} ->
      errors
      |> ActionErrors.unplaced_sentences(
        drawn_inputs(form, path, scope, state),
        resource_at(form, path)
      )
      |> Enum.map(&located(&1, form, path))
    end)
    |> Enum.uniq()
    |> case do
      [] -> socket
      sentences -> put_flash(socket, :error, Enum.join(sentences, "\n"))
    end
  end

  defp located(sentence, _form, []), do: sentence
  defp located(sentence, form, path), do: "#{path_label(form, path)} › #{sentence}"

  # Each field is named as the resource of the form holding it labels it.
  # People count items from one.
  defp path_label(form, path), do: form |> path_labels(path) |> Enum.join(" › ")

  defp path_labels(_form, []), do: []

  defp path_labels(form, [field | path]) do
    label = Labels.name(field, form && form.resource)
    sub_forms = form && Map.get(form.forms, field)

    case path do
      [index | path] when is_integer(index) ->
        sub_form = if is_list(sub_forms), do: Enum.at(sub_forms, index)
        ["#{label} #{index + 1}" | path_labels(sub_form, path)]

      path ->
        [label | path_labels(if(is_list(sub_forms), do: nil, else: sub_forms), path)]
    end
  end

  # The resource of the sub-form at `path`, as `drawn_inputs/4` walks it.
  defp resource_at(form, []), do: form.resource

  defp resource_at(form, [field | path]) do
    case {Map.get(form.forms, field), path} do
      {forms, [index | path]} when is_list(forms) ->
        forms |> Enum.at(index) |> then(&(&1 && resource_at(&1, path)))

      {nil, _path} ->
        nil

      {sub_form, path} ->
        resource_at(sub_form, path)
    end
  end

  # The inputs the page draws for the sub-form at `path`, a path as AshPhoenix
  # files errors under: each field is a key of `form.forms`, followed by the
  # item's index when it holds a list. A sub-form under a field this actor
  # cannot see is still built, and can refuse the save, but the page draws none
  # of its inputs. `state` is the form state of `form`, whose held fields draw
  # none either, and each sub-form's is found in it by the sub-form's name.
  defp drawn_inputs(form, [], scope, state),
    do: form |> input_names(scope) |> MapSet.difference(held_inputs(state))

  defp drawn_inputs(form, [field | path], scope, state) do
    {sub_form, path} =
      case {Map.fetch!(form.forms, field), path} do
        {forms, [index | path]} when is_list(forms) -> {Enum.at(forms, index), path}
        {sub_form, path} -> {sub_form, path}
      end

    sub_state = state && sub_form && AshQuick.FormState.find(state, sub_form.name)

    if field in input_names(form, scope) and field not in held_inputs(state),
      do: drawn_inputs(sub_form, path, scope, sub_state),
      else: MapSet.new()
  end

  # The names a form's error can be filed under for every field its state
  # hides or disables: the field's own and its inputs (`customer_id`).
  defp held_inputs(%AshQuick.FormState{fields: fields}) do
    for field <- fields,
        field.hidden? or field.disabled?,
        name <- [field.name | field.inputs],
        into: MapSet.new(),
        do: name
  end

  defp held_inputs(_state), do: MapSet.new()

  # A belongs_to is offered as its relationship, and its errors are filed under
  # the attribute behind it (`owner_id`), which the same input shows.
  defp input_names(form, scope) do
    form
    |> Utils.form_fields(scope)
    |> Enum.flat_map(fn
      %Ash.Resource.Relationships.BelongsTo{} = field -> [field.name, field.source_attribute]
      field -> [field.name]
    end)
    |> MapSet.new()
  end
end
