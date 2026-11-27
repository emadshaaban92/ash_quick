defmodule AshQuick.LiveView.FormStateFlow do
  @moduledoc false
  # Where a QuickView form's `AshQuick.FormState` is built, put through the
  # QuickView's `adjust_form/2` and held as `:ash_quick_form_state`, for the
  # page to draw the form from.
  #
  # It is never carried from one event to the next: each one builds it again
  # from the form it ends with. What the page posts is AshPhoenix's to read,
  # and Ash's to refuse.
  import Phoenix.Component, only: [assign: 3]

  alias Ash.Resource.Relationships.BelongsTo
  alias AshQuick.FormState
  alias AshQuick.LiveView.FormParams

  @assign :ash_quick_form_state

  # The state of the form the socket holds now, under `stage`.
  def store(%{assigns: %{form: %AshPhoenix.Form{} = form}} = socket, stage) do
    assign(socket, @assign, state(form, stage, socket))
  end

  def store(socket, _stage), do: assign(socket, @assign, nil)

  # The state of `form` as it stands, put through the hook.
  def build(form, stage, socket), do: state(form, stage, socket)

  # `form` and `params` with what the page left out of the post for every
  # field that `drawn`, the state the page was drawn from, hides or
  # disables. The page draws no input for such a field, so the post names
  # none of it, and that must keep what is stored:
  #
  #   * A sub-form field is taken out of what AshPhoenix counts as touched.
  #     AshPhoenix reads a touched sub-form missing from a post as emptied,
  #     so an update would save `[]` over the record's rows. Untouched, it is
  #     left out of the save, which keeps the record's value.
  #   * A stored embed row is saved whole, from what its row posts: a field
  #     it leaves out is saved blank. So each held field of such a row posts
  #     the row's stored value, unless the post names it.
  def hold_back(form, params, %FormState{} = drawn) do
    root = drawn.form.name

    Enum.reduce([drawn | FormState.taken_sub_forms(drawn)], {form, params}, fn row, acc ->
      held = Enum.filter(row.fields, &(&1.hidden? or &1.disabled?))

      if embed_row?(row),
        do: fill_row(acc, root, row, held),
        else: untouch_row(acc, root, row.form.name, held_sub_forms(held))
    end)
  end

  def hold_back(form, params, _drawn), do: {form, params}

  # The names of the root form's fields `state` hides or disables.
  def held_names(%FormState{fields: fields}),
    do: for(field <- fields, field.hidden? or field.disabled?, do: field.name)

  def held_names(_state), do: []

  defp embed_row?(%FormState{record: %resource{}}), do: Ash.Resource.Info.embedded?(resource)
  defp embed_row?(_row), do: false

  defp held_sub_forms(fields),
    do: for(%{kind: :nested, name: name} <- fields, do: to_string(name))

  defp untouch_row(acc, _root, _name, []), do: acc

  defp untouch_row({form, params}, root, root, keys),
    do: {untouch(form, keys), untouch_param(params, keys)}

  defp untouch_row({form, params}, root, name, keys) do
    form = AshPhoenix.Form.update_form(form, name, &untouch(&1, keys), mark_as_touched?: false)
    {form, update_path(params, param_path(root, name), &untouch_param(&1, keys))}
  end

  defp fill_row(acc, _root, _row, []), do: acc

  defp fill_row({form, params}, root, row, held) do
    fill = fn row_params -> Enum.reduce(held, row_params, &fill_field(row.record, &1, &2)) end
    {form, update_path(params, param_path(root, row.form.name), fill)}
  end

  defp fill_field(record, field, row_params) do
    case embed_param(record, field) do
      {:ok, value} ->
        Enum.reduce(field.inputs, row_params, &Map.put_new(&2, to_string(&1), value))

      :none ->
        row_params
    end
  end

  # The value a stored embed row has for `field`, as its params post it: an
  # attribute's own, a sub-form field's rows. Nothing for an argument, which
  # a stored row has no value of, or for an embed the row holds none of:
  # `%{}` would be an empty one.
  defp embed_param(record, %{source: %Ash.Resource.Attribute{} = attribute}) do
    value = Map.get(record, attribute.name)

    cond do
      not Ash.Type.embedded_type?(attribute.type) ->
        {:ok, FormParams.attribute_param(value, attribute.type)}

      is_nil(value) ->
        :none

      true ->
        {:ok, FormParams.embedded_params(value)}
    end
  end

  defp embed_param(record, %{source: %BelongsTo{source_attribute: attribute}}),
    do: {:ok, Map.get(record, attribute)}

  defp embed_param(_record, _field), do: :none

  defp untouch(form, keys),
    do: %{form | touched_forms: MapSet.difference(form.touched_forms, MapSet.new(keys))}

  defp untouch_param(%{"_touched" => touched} = params, keys) when is_binary(touched) do
    case touched |> String.split(",", trim: true) |> Enum.reject(&(&1 in keys)) do
      [] -> Map.delete(params, "_touched")
      kept -> Map.put(params, "_touched", Enum.join(kept, ","))
    end
  end

  defp untouch_param(params, _keys), do: params

  # `form[lines][0][parts]` under the root `form` is `["lines", "0", "parts"]`.
  defp param_path(root, name) do
    name
    |> String.replace_prefix(root, "")
    |> then(&Regex.scan(~r/\[([^\]]*)\]/, &1, capture: :all_but_first))
    |> List.flatten()
  end

  defp update_path(%{} = params, [], fun) when not is_struct(params), do: fun.(params)

  defp update_path(%{} = params, [key | path], fun) when not is_struct(params) do
    case Map.fetch(params, key) do
      {:ok, value} -> Map.put(params, key, update_path(value, path, fun))
      :error -> params
    end
  end

  defp update_path(value, _path, _fun), do: value

  # Whether the form takes `field`'s uploads: not when the state the socket
  # holds hides or disables it, or a field above its sub-form. An upload is
  # held by the server, not posted, so a file picked before the field was
  # hidden is left unconsumed rather than stored for a field the page no
  # longer shows.
  def takes_upload?(socket, form, field) do
    with %FormState{} = state <- socket.assigns[@assign],
         %FormState{} = held <- FormState.find(state, form.name),
         %{hidden?: hidden?, disabled?: disabled?} <- FormState.field(held, field.name) do
      not (hidden? or disabled?) and taken?(state, form.name)
    else
      _not_held_back -> true
    end
  end

  defp taken?(%FormState{form: %{name: name}}, name), do: true

  defp taken?(state, name),
    do: state |> FormState.taken_sub_forms() |> Enum.any?(&(&1.form.name == name))

  defp state(form, stage, socket) do
    assigns = socket.assigns
    options = assigns[:options]

    built =
      FormState.new(form, stage,
        scope: assigns[:scope],
        widgets: (options && options.form_widgets) || %{}
      )

    FormState.narrow(built, adjust(built, socket.view, options))
  end

  defp adjust(state, view, options) do
    if is_atom(view) and function_exported?(view, :__ash_quick_adjust_form__, 2),
      do: view.__ash_quick_adjust_form__(state, options),
      else: state
  end
end
