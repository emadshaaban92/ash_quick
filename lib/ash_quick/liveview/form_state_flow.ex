defmodule AshQuick.LiveView.FormStateFlow do
  @moduledoc false
  # Where a QuickView form's `AshQuick.FormState` is built, put through the
  # QuickView's `adjust_form/2` and held as `:ash_quick_form_state`, and where
  # what it hides is taken out of a post.
  #
  # It is never carried from one event to the next: each one builds it again
  # from the form it ends with. Only the sub-form handling below reads the one
  # before, to put back an embed's rows the page has not drawn yet.
  import Phoenix.Component, only: [assign: 3]

  alias AshQuick.FormState
  alias AshQuick.LiveView.FormParams

  @assign :ash_quick_form_state

  # The state of the form the socket holds now, under `stage`.
  def store(%{assigns: %{form: %AshPhoenix.Form{} = form}} = socket, stage) do
    assign(socket, @assign, state(form, stage, socket))
  end

  def store(socket, _stage), do: assign(socket, @assign, nil)

  # The state of `validated`, the form `form` validated with `params`, and
  # the params less those of every field it hides or disables: when any are
  # dropped, `form` is validated again without them and the state built
  # again, until a pass changes nothing. Each pass that goes on drops a param,
  # untouches a sub-form or puts back a record's rows, none of which a later
  # pass undoes, so it ends, and one pass is the usual case.
  #
  # A sub-form is not just dropped. AshPhoenix reads a sub-form key it counts
  # as touched and the params lack as "emptied", so a hidden one would save
  # `[]` over an update's rows. An embed held back on an update posts the
  # record's own rows instead, and so does one shown again after being held
  # back, whose inputs the page has not drawn yet. Any other sub-form is
  # taken out of what the form counts as touched.
  def settle(form, params, validated, stage, socket, validate_opts \\ []) do
    state = state(validated, stage, socket)
    kept = kept_rows(state, form, params, socket.assigns[@assign])
    kept_keys = Map.keys(kept)

    dropped =
      state
      |> FormState.dropped_params()
      |> Enum.filter(&(Map.has_key?(params, &1) and &1 not in kept_keys))

    restored = for {key, rows} <- kept, Map.get(params, key) != rows, do: key
    untouched = touched_sub_forms(state, form, params) -- kept_keys

    if dropped == [] and restored == [] and untouched == [] do
      # AshPhoenix counts a sub-form it built from the record as touched,
      # which would make the next validate or the submit read it as emptied.
      held = held_sub_forms(state, validated) -- kept_keys
      {params, validated |> untouch(held) |> mark_required(state, stage), state}
    else
      form = untouch(form, untouched)

      params =
        params |> Map.drop(dropped) |> Map.merge(kept) |> untouch_param(untouched)

      revalidated = AshPhoenix.Form.validate(form, params, validate_opts)
      settle(form, params, revalidated, stage, socket, validate_opts)
    end
  end

  # The record's rows, as params, of each embed drawn as sub-forms on an
  # update that the state holds back, or that the state before it held back
  # and the params do not name.
  defp kept_rows(state, form, params, previous) do
    case form.data do
      %_{} = record when form.type == :update ->
        for field <- state.fields,
            embed_sub_form?(field, form),
            key = to_string(field.name),
            held?(field) or (held_before?(previous, field) and not Map.has_key?(params, key)),
            into: %{},
            do: {key, FormParams.embedded_params(Map.get(record, field.name))}

      _create ->
        %{}
    end
  end

  defp embed_sub_form?(%{source: %Ash.Resource.Attribute{type: type}, name: name}, form),
    do: Keyword.has_key?(form.form_keys, name) and Ash.Type.embedded_type?(type)

  defp embed_sub_form?(_field, _form), do: false

  defp held?(field), do: field.hidden? or field.disabled?

  defp held_before?(%FormState{} = previous, field) do
    case FormState.field(previous, field.name) do
      %{} = was -> held?(was)
      nil -> false
    end
  end

  defp held_before?(_previous, _field), do: false

  # The keys of hidden or disabled fields drawn as sub-forms that the form
  # validated from, or the `_touched` the page posted, still counts as
  # touched. Only what this module can take back is asked about, so once both
  # are clear the loop ends.
  defp touched_sub_forms(state, form, params) do
    sub_forms = MapSet.new(form.form_keys, fn {key, _opts} -> to_string(key) end)
    posted = touched_param(params)

    for key <- FormState.dropped_inputs(state),
        MapSet.member?(sub_forms, key),
        MapSet.member?(form.touched_forms, key) or key in posted,
        do: key
  end

  defp held_sub_forms(state, form) do
    sub_forms = MapSet.new(form.form_keys, fn {key, _opts} -> to_string(key) end)
    Enum.filter(FormState.dropped_inputs(state), &MapSet.member?(sub_forms, &1))
  end

  defp untouch(form, []), do: form

  defp untouch(form, keys),
    do: %{form | touched_forms: MapSet.difference(form.touched_forms, MapSet.new(keys))}

  defp untouch_param(params, []), do: params

  defp untouch_param(%{"_touched" => touched} = params, keys) when is_binary(touched) do
    case Enum.reject(touched_param(params), &(&1 in keys)) do
      [] -> Map.delete(params, "_touched")
      kept -> Map.put(params, "_touched", Enum.join(kept, ","))
    end
  end

  defp untouch_param(params, _keys), do: params

  defp touched_param(%{"_touched" => touched}) when is_binary(touched),
    do: String.split(touched, ",", trim: true)

  defp touched_param(_params), do: []

  # Whether the root form takes `field`'s uploads: not when the state the
  # socket holds hides or disables it. Its params would be dropped anyway, so
  # the file is left unconsumed rather than stored for nothing.
  def takes_upload?(socket, form, field) do
    with false <- String.contains?(form.name, "["),
         %FormState{} = state <- socket.assigns[@assign],
         %{hidden?: hidden?, disabled?: disabled?} <- FormState.field(state, field.name) do
      not (hidden? or disabled?)
    else
      _not_held_back -> true
    end
  end

  # The state of `form` as it stands, put through the hook.
  def build(form, stage, socket), do: state(form, stage, socket)

  # `form` with an error under every field `require/3` marks that is blank,
  # or `:ok` when there is none.
  def enforce(%FormState{} = state, form) do
    case FormState.blank_required(state) do
      [] ->
        :ok

      fields ->
        form =
          Enum.reduce(fields, form, fn field, form ->
            [input | _] = field.inputs

            AshPhoenix.Form.add_error(
              form,
              Ash.Error.Changes.Required.exception(
                field: input,
                type: required_type(field.source),
                resource: form.resource
              )
            )
          end)

        {:error, %{form | errors: true, submitted_once?: true}}
    end
  end

  # Once a save was refused, a change keeps the error under a field
  # `require/3` marks that is still blank, as Ash keeps its own: validating
  # again would drop the one `enforce/2` added. Only shown, never refused on.
  defp mark_required(%{submitted_once?: true} = form, state, :validate) do
    case enforce(state, form) do
      :ok -> form
      {:error, marked} -> marked
    end
  end

  defp mark_required(form, _state, _stage), do: form

  defp required_type(%Ash.Resource.Actions.Argument{}), do: :argument
  defp required_type(_source), do: :attribute

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
