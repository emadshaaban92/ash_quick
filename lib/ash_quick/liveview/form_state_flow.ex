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
  #
  # Each sub-form's state is held to its row of the params the same way, at
  # the path its name gives (`form[lines][0]` is `params["lines"]["0"]`):
  # see `strip_rows/3`. So the rows are put in the order AshPhoenix numbers
  # them first (`number_rows/2`).
  def settle(form, params, validated, stage, socket, validate_opts \\ []) do
    state = state(validated, stage, socket)

    case number_rows(params, state) do
      ^params ->
        settle_numbered(form, params, validated, state, stage, socket, validate_opts)

      numbered ->
        revalidated = AshPhoenix.Form.validate(form, numbered, validate_opts)
        settle(form, numbered, revalidated, stage, socket, validate_opts)
    end
  end

  defp settle_numbered(form, params, validated, state, stage, socket, validate_opts) do
    previous = socket.assigns[@assign]
    kept = kept_rows(state, form, params, previous)
    kept_keys = Map.keys(kept)

    dropped =
      state
      |> FormState.dropped_params()
      |> Enum.filter(&(Map.has_key?(params, &1) and &1 not in kept_keys))

    restored = for {key, rows} <- kept, Map.get(params, key) != rows, do: key
    untouched = touched_sub_forms(state, form, params) -- kept_keys
    rows_params = strip_rows(params, state, previous)

    if dropped == [] and restored == [] and untouched == [] and rows_params == params do
      # AshPhoenix counts a sub-form it built from the record as touched,
      # which would make the next validate or the submit read it as emptied.
      held = held_sub_forms(state, validated) -- kept_keys
      {params, validated |> untouch(held) |> mark_required(state, stage), state}
    else
      form = untouch(form, untouched)

      params =
        rows_params |> Map.drop(dropped) |> Map.merge(kept) |> untouch_param(untouched)

      revalidated = AshPhoenix.Form.validate(form, params, validate_opts)
      settle(form, params, revalidated, stage, socket, validate_opts)
    end
  end

  # `params` with the rows of every list sub-form keyed as AshPhoenix names
  # them: `"0"` up to one less than their count, in the order of the keys
  # posted. AshPhoenix sorts the posted keys and numbers the rows the same
  # way, so a hand-made post keyed `"1"` and `"5"` would otherwise have the
  # rule of row `[0]` held to the params under `"0"`, which are not its. A
  # template's `_drop_`, `_sort_` and `_add_` keys (AshPhoenix's remove,
  # reorder and add inputs) are applied here as AshPhoenix applies them,
  # and taken out, so the rows' names say where each one ends up.
  defp number_rows(params, %FormState{} = state) when is_map(params) and not is_struct(params) do
    Enum.reduce(state.forms, params, fn {name, rows}, params ->
      opts = state.form.form_keys[name] || []
      key = to_string(opts[:as] || name)

      case {opts[:type], Map.get(params, key)} do
        {:list, posted} when is_list(posted) or (is_map(posted) and not is_struct(posted)) ->
          number_list(params, key, posted, rows)

        {:single, %{} = posted} when not is_struct(posted) ->
          Map.put(params, key, number_rows(posted, List.first(rows)))

        _not_posted ->
          params
      end
    end)
  end

  defp number_rows(params, _state), do: params

  @controls ~w(_drop_ _sort_ _add_)

  defp number_list(params, key, posted, rows) do
    controls = Enum.map(@controls, &(&1 <> key))

    if is_list(posted) and not Enum.any?(controls, &Map.has_key?(params, &1)) do
      # Numbered by its order already, as the record's own rows are put back.
      numbered =
        posted
        |> Enum.with_index()
        |> Enum.map(fn {row, index} -> number_rows(row, Enum.at(rows, index)) end)

      Map.put(params, key, numbered)
    else
      case posted |> indexed() |> drop_rows(params[hd(controls)]) do
        {:ok, entries} ->
          entries
          |> sort_rows(params[Enum.at(controls, 1)])
          |> add_row(params[Enum.at(controls, 2)])
          |> numbered_map(rows)
          |> then(&(params |> Map.drop(controls) |> Map.put(key, &1)))

        # AshPhoenix refuses a key that is no number: nothing to line up.
        :error ->
          params
      end
    end
  end

  defp numbered_map(posted, rows) do
    posted
    |> Enum.with_index()
    |> Map.new(fn {row, index} -> {to_string(index), number_rows(row, Enum.at(rows, index))} end)
  end

  # The posted rows as `{index, row}`, or :error when a key is no number.
  defp indexed(posted) when is_list(posted), do: Enum.with_index(posted, &{&2, &1})

  defp indexed(posted) do
    entries = Enum.map(posted, fn {key, row} -> {integer_key(key), row} end)
    if Enum.all?(entries, &is_integer(elem(&1, 0))), do: entries, else: :error
  end

  # As AshPhoenix's `drop_nested/2`: the rows a `_drop_` list names go.
  defp drop_rows(:error, _drop), do: :error

  defp drop_rows(entries, drop) when is_list(drop) do
    dropped = drop |> List.wrap() |> Enum.map(&integer_key/1)
    {:ok, Enum.reject(entries, &(elem(&1, 0) in dropped))}
  end

  defp drop_rows(entries, _drop), do: {:ok, entries}

  # As AshPhoenix's `sort_nested/2`: the row posted at position `p` goes to
  # the index the `_sort_` list holds at `p`, and the rows then go by index.
  # The rows come back as a plain list.
  defp sort_rows(entries, sort) when is_list(sort) do
    by_index = Map.new(entries)

    sort
    |> Enum.with_index()
    |> Enum.flat_map(fn {target, position} ->
      case {integer_key(target), Map.fetch(by_index, position)} do
        {index, {:ok, row}} when is_integer(index) -> [{index, row}]
        _gone -> []
      end
    end)
    |> sort_rows(nil)
  end

  defp sort_rows(entries, _sort),
    do: entries |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

  # As AshPhoenix's `add_nested/2`: an `_add_` key puts an empty row in, at
  # the start, the end or the index it names.
  defp add_row(rows, nil), do: rows

  defp add_row(rows, at), do: List.insert_at(rows, add_index(at), %{})

  defp add_index("start"), do: 0

  defp add_index(at) do
    case integer_key(at) do
      index when is_integer(index) -> index
      _end -> -1
    end
  end

  defp integer_key(key) when is_binary(key) do
    case Integer.parse(key) do
      {index, ""} -> index
      _not_an_index -> key
    end
  end

  defp integer_key(key), do: key

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
    blank =
      for held <- [state | FormState.taken_sub_forms(state)],
          field <- FormState.blank_required(held),
          do: {held.form.name, field}

    case blank do
      [] ->
        :ok

      blank ->
        form = Enum.reduce(blank, form, &put_required/2)

        {:error, %{form | errors: true, submitted_once?: true}}
    end
  end

  defp put_required({name, field}, %{name: name} = form), do: add_required(form, field)

  # A sub-form shows its errors once it is marked as the root is.
  defp put_required({name, field}, form) do
    AshPhoenix.Form.update_form(
      form,
      name,
      &%{add_required(&1, field) | errors: true, submitted_once?: true},
      mark_as_touched?: false
    )
  end

  defp add_required(form, field) do
    [input | _] = field.inputs

    AshPhoenix.Form.add_error(
      form,
      Ash.Error.Changes.Required.exception(
        field: input,
        type: required_type(field.source),
        resource: form.resource
      )
    )
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
