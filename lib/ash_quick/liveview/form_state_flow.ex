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

  alias Ash.Resource.Relationships.BelongsTo
  alias AshQuick.FormState
  alias AshQuick.LiveView.FormParams
  alias AshQuick.LiveView.SubForms

  @assign :ash_quick_form_state

  # The state of the form the socket holds now, under `stage`.
  def store(%{assigns: %{form: %AshPhoenix.Form{} = form}} = socket, stage) do
    assign(socket, @assign, state(form, stage, socket))
  end

  def store(socket, _stage), do: assign(socket, @assign, nil)

  # The state of `validated`, a form just validated, and its params less
  # those of every field the state hides or disables: when any are dropped,
  # the form is validated again without them and the state built again, until
  # a pass changes nothing. Each pass that goes on drops a param, untouches a
  # sub-form or puts back a record's rows, none of which a later pass undoes,
  # so it ends, and one pass is the usual case.
  #
  # A sub-form is not just dropped. AshPhoenix reads a sub-form key it counts
  # as touched and the params lack as "emptied", so a hidden one would save
  # `[]` over an update's rows. An embed held back on an update posts the
  # record's own rows instead, and so does one shown again after being held
  # back, whose inputs the page has not drawn yet. Any other sub-form is
  # taken out of what the form counts as touched.
  #
  # Each sub-form's state is held to its row of the params the same way, at
  # the path its name gives (`form[lines][0]` is `params["lines"]["0"]`):
  # see `strip_rows/3`. Which rows a post holds, and which stored row each
  # one is, is AshPhoenix's to say (`SubForms.validate/3`): the params are
  # read back from the validated form (`numbered/1`), where the rows are
  # keyed as the sub-forms are named.
  def settle(validated, stage, socket, validate_opts \\ []) do
    state = state(validated, stage, socket)
    params = numbered(validated)
    settle_numbered(validated, params, validated, state, stage, socket, validate_opts)
  end

  # The params `form` was validated with, as AshPhoenix left them: every
  # list's rows keyed "0" up, its control keys applied and gone.
  defp numbered(%Phoenix.HTML.Form{source: source}), do: numbered(source)

  defp numbered(%AshPhoenix.Form{} = form) do
    Enum.reduce(form.form_keys, form.params || %{}, fn {key, opts}, params ->
      name = to_string(opts[:as] || key)

      if Map.has_key?(params, name),
        do: put_numbered(params, name, form.forms[key]),
        else: params
    end)
  end

  defp put_numbered(params, name, [_ | _] = rows),
    do: Map.put(params, name, rows |> Enum.map(&numbered/1) |> indexed())

  defp put_numbered(params, name, %AshPhoenix.Form{} = row),
    do: Map.put(params, name, numbered(row))

  # A key AshPhoenix put in itself, for a sub-form it counts as touched that
  # the post left out. It puts it in again each time.
  defp put_numbered(params, name, none) when none in [[], nil],
    do: if(Map.get(params, name) in [nil, %{}], do: Map.delete(params, name), else: params)

  defp put_numbered(params, _name, _other), do: params

  defp settle_numbered(form, params, validated, state, stage, socket, validate_opts) do
    previous = socket.assigns[@assign]
    kept = kept_rows(state, form, params, previous)
    kept_keys = Map.keys(kept)

    dropped =
      state
      |> FormState.dropped_params()
      |> Enum.filter(&(Map.has_key?(params, &1) and &1 not in kept_keys))

    restored = for {key, rows} <- kept, not same?(Map.get(params, key), rows), do: key
    untouched = touched_sub_forms(state, form, params) -- kept_keys
    rows_params = strip_rows(params, state, previous)

    if dropped == [] and restored == [] and untouched == [] and same?(rows_params, params) do
      # AshPhoenix counts a sub-form it built from the record as touched,
      # which would make the next validate or the submit read it as emptied.
      held = held_sub_forms(state, validated) -- kept_keys
      {params, validated |> untouch(held) |> mark_required(state, stage), state}
    else
      form = untouch(form, untouched)

      params =
        rows_params |> Map.drop(dropped) |> Map.merge(kept) |> untouch_param(untouched)

      revalidated = SubForms.validate(form, params, validate_opts)
      state = state(revalidated, stage, socket)
      settle_numbered(form, params, revalidated, state, stage, socket, validate_opts)
    end
  end

  # `params` with each sub-form's row held to that sub-form's state: the
  # params of a field it hides or disables are dropped from the row, or, on a
  # row the record already holds, set to the row's own value. An embed holds
  # its rows as a whole, so a row posted without a field is read as a row
  # without it, and dropping would blank the row's value on save. A sub-form
  # field held back on a row posts its stored rows, and so does one the row's
  # state before held back that the row does not name, as at the root. Rows
  # under a field the state holds back are not looked at: the root takes or
  # keeps that field whole.
  defp strip_rows(params, state, previous) do
    root = state.form.name

    state
    |> FormState.taken_sub_forms()
    |> Enum.reduce(params, fn row, params ->
      path = param_path(root, row.form.name)
      before = previous && FormState.find(previous, row.form.name)

      case get_path(params, path) do
        %{} = row_params when not is_struct(row_params) ->
          put_path(params, path, strip_row(row, row_params, before))

        _not_posted ->
          params
      end
    end)
  end

  defp strip_row(row, row_params, before) do
    Enum.reduce(row.fields, row_params, fn field, row_params ->
      cond do
        held?(field) ->
          hold_field(row, field, row_params)

        sub_form_shown_again?(row, field, row_params, before) ->
          hold_field(row, field, row_params)

        true ->
          row_params
      end
    end)
  end

  defp sub_form_shown_again?(row, field, row_params, before) do
    row.record != nil and field.kind == :nested and held_before?(before, field) and
      not Map.has_key?(row_params, to_string(field.name))
  end

  defp hold_field(row, field, row_params) do
    keys = Enum.map(field.inputs, &to_string/1)

    row_params =
      Map.drop(row_params, Enum.map(keys, &("_unused_" <> &1)))

    case stored_param(row.record, field) do
      {:ok, value} ->
        Enum.reduce(keys, row_params, &Map.put(&2, &1, value))

      :none ->
        row_params |> Map.drop(keys) |> untouch_param(keys)
    end
  end

  # The value a stored embed row has for `field`, as its params post it: an
  # attribute's own, a sub-form field's rows. Nothing for a new row, or for
  # an argument, which a stored row has no value of. Only an embed is saved
  # whole: the row of a relationship the action manages is updated, and
  # keeps a field its params leave out, so that one is dropped.
  defp stored_param(%row{} = record, field) do
    if Ash.Resource.Info.embedded?(row), do: embed_param(record, field), else: :none
  end

  defp stored_param(_record, _field), do: :none

  defp embed_param(record, %{source: %Ash.Resource.Attribute{} = attribute}) do
    value = Map.get(record, attribute.name)

    cond do
      not Ash.Type.embedded_type?(attribute.type) ->
        {:ok, FormParams.attribute_param(value, attribute.type)}

      # Left out, the row is saved without it, which is the nil it holds.
      # `%{}` would be an empty embed.
      is_nil(value) ->
        :none

      true ->
        {:ok, FormParams.embedded_params(value)}
    end
  end

  defp embed_param(record, %{source: %BelongsTo{source_attribute: attribute}}),
    do: {:ok, Map.get(record, attribute)}

  defp embed_param(_record, _field), do: :none

  # `form[lines][0][parts]` under the root `form` is `["lines", "0", "parts"]`.
  defp param_path(root, name) do
    name
    |> String.replace_prefix(root, "")
    |> then(&Regex.scan(~r/\[([^\]]*)\]/, &1, capture: :all_but_first))
    |> List.flatten()
  end

  defp get_path(value, []), do: value

  defp get_path(%{} = params, [key | path]) when not is_struct(params),
    do: params |> Map.get(key) |> get_path(path)

  defp get_path(list, [key | path]) when is_list(list) do
    case Integer.parse(key) do
      {index, ""} -> list |> Enum.at(index) |> get_path(path)
      _not_an_index -> nil
    end
  end

  defp get_path(_value, _path), do: nil

  defp put_path(_value, [], new), do: new

  defp put_path(%{} = params, [key | path], new),
    do: Map.put(params, key, put_path(Map.get(params, key), path, new))

  defp put_path(list, [key | path], new) when is_list(list) do
    {index, ""} = Integer.parse(key)
    List.update_at(list, index, &put_path(&1, path, new))
  end

  # Whether two params are the same once AshPhoenix numbers their rows: it
  # reads a list of rows as the rows keyed "0" up.
  defp same?(a, b) when is_list(a) and is_map(b) and not is_struct(b), do: same?(indexed(a), b)
  defp same?(a, b) when is_list(b) and is_map(a) and not is_struct(a), do: same?(a, indexed(b))

  defp same?(a, b) when is_list(a) and is_list(b),
    do: length(a) == length(b) and Enum.all?(Enum.zip(a, b), fn {x, y} -> same?(x, y) end)

  defp same?(a, b) when is_map(a) and is_map(b) and not is_struct(a) and not is_struct(b) do
    Map.keys(a) == Map.keys(b) and
      Enum.all?(a, fn {key, value} -> same?(value, Map.get(b, key)) end)
  end

  defp same?(a, b), do: a == b

  defp indexed(rows),
    do: rows |> Enum.with_index() |> Map.new(fn {row, at} -> {to_string(at), row} end)

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
            # A single embed the record holds none of posts nothing: `%{}`
            # would save an empty one over nil. Left out and untouched, the
            # update keeps the record's nil.
            value = Map.get(record, field.name),
            value != nil,
            into: %{},
            do: {key, FormParams.embedded_params(value)}

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
  #
  # A sub-form's field is asked of that sub-form's state, which takes nothing
  # either when a field above it is held back.
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

  # The state of `form` as it stands, put through the hook.
  def build(form, stage, socket), do: state(form, stage, socket)

  # `form` with an error under every field `require/3` marks that is blank,
  # on the root form or a sub-form the state takes, or `:ok` when there is
  # none. A sub-form's error is put on that sub-form, found by its name.
  def enforce(%FormState{} = state, form) do
    case required_errors(state) do
      [] -> :ok
      errors -> {:error, %{put_errors(form, errors) | errors: true, submitted_once?: true}}
    end
  end

  defp required_errors(state) do
    for held <- [state | FormState.taken_sub_forms(state)],
        field <- FormState.blank_required(held),
        do: {held.form.name, field, required_error(field, held.form)}
  end

  defp put_errors(form, errors), do: Enum.reduce(errors, form, &put_error/2)

  defp put_error({name, _field, error}, %{name: name} = form),
    do: AshPhoenix.Form.add_error(form, error)

  # A sub-form shows its errors once it is marked as the root is.
  defp put_error({name, _field, error}, form) do
    AshPhoenix.Form.update_form(
      form,
      name,
      &%{AshPhoenix.Form.add_error(&1, error) | errors: true, submitted_once?: true},
      mark_as_touched?: false
    )
  end

  defp required_error(field, form) do
    [input | _] = field.inputs

    Ash.Error.Changes.Required.exception(
      field: input,
      type: required_type(field.source),
      resource: form.resource
    )
  end

  # Once a save was refused, a change keeps the error under a field
  # `require/3` marks that is still blank, as Ash keeps its own: validating
  # again would drop the one `enforce/2` added. Only shown, never refused on.
  defp mark_required(%{submitted_once?: true} = form, state, :validate) do
    case required_errors(state) do
      [] -> form
      errors -> %{put_errors(form, errors) | errors: true, submitted_once?: true}
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
