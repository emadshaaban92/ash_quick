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
  alias AshQuick.LiveView.FormRecords
  alias AshQuick.LiveView.Utils

  @assign :ash_quick_form_state

  @not_offered "is not one of the choices offered"

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

    case number_rows(params, state, state.form.id) do
      {^params, _moves} ->
        settle_numbered(form, params, validated, state, stage, socket, validate_opts)

      {numbered, moves} ->
        form = move_rows(form, moves)
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

  # AshPhoenix matches a posted row to the sub-form at its index, which is
  # the row's own only while nothing moved: after a `_drop_` or a `_sort_`,
  # or a post that leaves a row out, the row at index 0 may be the one the
  # form held at 1, and AshPhoenix would give it the record held at 0. So
  # the form's own rows are moved first as the post moved them, each renamed
  # for where it ends up, its sub-forms with it, as AshPhoenix's
  # `sort_forms/3` renames them. A dropped row, and the place of one `_add_`
  # put in, hold no sub-form, and a new one is built there.
  defp move_rows(%Phoenix.HTML.Form{source: source} = form, moves) when moves != %{},
    do: source |> move_rows(moves) |> Phoenix.HTML.FormData.to_form(form.options)

  defp move_rows(%AshPhoenix.Form{} = form, moves) when moves != %{} do
    forms =
      Map.new(form.forms, fn {key, sub_forms} ->
        sub_forms =
          case {sub_forms, Map.fetch(moves, {form.id, to_string(key)})} do
            {[_ | _], {:ok, sources}} -> move_list(sub_forms, sources, moves, form, key)
            {sub_forms, _not_moved} -> move_each(sub_forms, moves)
          end

        {key, sub_forms}
      end)

    %{form | forms: forms}
  end

  defp move_rows(form, _moves), do: form

  defp move_each(sub_forms, moves) when is_list(sub_forms),
    do: Enum.map(sub_forms, &move_rows(&1, moves))

  defp move_each(sub_form, moves), do: move_rows(sub_form, moves)

  defp move_list(sub_forms, sources, moves, form, key) do
    by_id = Map.new(sub_forms, &{&1.id, &1})

    sources
    |> Enum.sort()
    |> Enum.flat_map(fn {at, source} ->
      case source && Map.fetch(by_id, "#{form.id}_#{key}_#{source}") do
        {:ok, sub_form} ->
          name = "#{form.name}[#{key}][#{at}]"
          id = "#{form.id}_#{key}_#{at}"
          [sub_form |> move_rows(moves) |> rename({sub_form.name, name}, {sub_form.id, id})]

        _none ->
          []
      end
    end)
  end

  # As AshPhoenix renames a sub-form it moves, and every sub-form under it.
  defp rename(form, {old_name, name}, {old_id, id}) do
    forms =
      Map.new(form.forms || %{}, fn
        {key, sub_forms} when is_list(sub_forms) ->
          {key, Enum.map(sub_forms, &rename_under(&1, {old_name, name}, {old_id, id}))}

        {key, nil} ->
          {key, nil}

        {key, sub_form} ->
          {key, rename_under(sub_form, {old_name, name}, {old_id, id})}
      end)

    %{form | name: name, id: id, forms: forms}
  end

  defp rename_under(sub_form, {old_name, name}, {old_id, id}) do
    rename(
      sub_form,
      {sub_form.name, String.replace_leading(sub_form.name, old_name, name)},
      {sub_form.id, String.replace_leading(sub_form.id, old_id, id)}
    )
  end

  # `params` with the rows of every list sub-form keyed as AshPhoenix names
  # them: `"0"` up to one less than their count, in the order of the keys
  # posted. AshPhoenix sorts the posted keys and numbers the rows the same
  # way, so a hand-made post keyed `"1"` and `"5"` would otherwise have the
  # rule of row `[0]` held to the params under `"0"`, which are not its. A
  # template's `_drop_`, `_sort_` and `_add_` keys (AshPhoenix's remove,
  # reorder and add inputs) are applied here as AshPhoenix applies them,
  # and taken out, so the rows' names say where each one ends up.
  #
  # Comes back with the moves those keys made, and those of rows posted
  # under other keys than the ones they end up with: for the list under the
  # sub-form whose id is `id`, which index each row was posted under (nil
  # for a row `_add_` put in). `id` is the sub-form's id in the form the
  # post was made from. Each row keeps the stored row it was posted for.
  defp number_rows(params, %FormState{} = state, id)
       when is_map(params) and not is_struct(params) do
    Enum.reduce(state.forms, {params, %{}}, fn {name, rows}, {params, moves} ->
      opts = state.form.form_keys[name] || []
      key = to_string(opts[:as] || name)

      {params, moved} =
        case {opts[:type], Map.get(params, key)} do
          {:list, posted} when is_list(posted) or (is_map(posted) and not is_struct(posted)) ->
            number_list(params, {key, name}, posted, rows, id)

          {:single, %{} = posted} when not is_struct(posted) ->
            {row, moved} = number_rows(posted, List.first(rows), "#{id}_#{name}")
            {Map.put(params, key, row), moved}

          _not_posted ->
            {params, %{}}
        end

      {params, Map.merge(moves, moved)}
    end)
  end

  defp number_rows(params, _state, _id), do: {params, %{}}

  @controls ~w(_drop_ _sort_ _add_)

  defp number_list(params, {key, name}, posted, rows, id) do
    controls = Enum.map(@controls, &(&1 <> key))

    if is_list(posted) and not Enum.any?(controls, &Map.has_key?(params, &1)) do
      # Numbered by its order already, as the record's own rows are put back.
      {numbered, moves} =
        posted
        |> Enum.with_index(&{&2, &1})
        |> number_each(rows, "#{id}_#{name}")

      {Map.put(params, key, numbered), moves}
    else
      case posted |> indexed() |> drop_rows(params[hd(controls)]) do
        {:ok, entries} -> number_moved(params, entries, controls, {key, name}, rows, id)
        # AshPhoenix refuses a key that is no number: nothing to line up.
        :error -> {params, %{}}
      end
    end
  end

  # The rows left after a drop, sorted and added to as the post says, each
  # beside the index it was posted under. A row posted under another index
  # than the one it ends up at moved, with or without a control key: a post
  # keyed `"1"` alone is stored row 1, not row 0, so the form's rows are
  # moved with it. Only rows posted under `"0"` up to one less than their
  # count, with no control key, are left where they are.
  defp number_moved(params, entries, controls, {key, name}, rows, id) do
    [_drop, sort, add] = Enum.map(controls, &params[&1])
    controlled? = Enum.any?(controls, &Map.has_key?(params, &1))

    entries =
      entries
      |> Enum.map(fn {index, row} -> {index, {index, row}} end)
      |> sort_rows(sort)
      |> add_row(add)
      |> claim_once()

    {numbered, moves} = number_each(entries, rows, "#{id}_#{name}")
    numbered = numbered |> Enum.with_index(&{to_string(&2), &1}) |> Map.new()
    params = params |> Map.drop(controls) |> Map.put(key, numbered)
    sources = Enum.with_index(entries, fn {source, _row}, at -> {at, source} end)

    if controlled? or Enum.any?(sources, fn {at, source} -> at != source end) do
      {params, Map.put(moves, {id, to_string(name)}, Map.new(sources))}
    else
      {params, moves}
    end
  end

  # Two keys can name the same index (`"1"` and `"01"`): only the row whose
  # key sorts first as text (`"01"`) keeps that stored row, and the others
  # are new rows, as a key past the stored rows is.
  defp claim_once(entries) do
    {entries, _claimed} =
      Enum.map_reduce(entries, MapSet.new(), fn {source, row}, claimed ->
        if is_integer(source) and MapSet.member?(claimed, source),
          do: {{nil, row}, claimed},
          else: {{source, row}, MapSet.put(claimed, source)}
      end)

    entries
  end

  # Each `{source, row}` numbered in turn, a row's own rows under the id its
  # sub-form had when posted.
  defp number_each(entries, rows, prefix) do
    entries
    |> Enum.with_index()
    |> Enum.map_reduce(%{}, fn {{source, row}, at}, moves ->
      id = if is_integer(source), do: "#{prefix}_#{source}", else: "#{prefix}_added_#{at}"
      {row, moved} = number_rows(row, Enum.at(rows, at), id)
      {row, Map.merge(moves, moved)}
    end)
  end

  # The posted rows as `{index, row}`, or :error when a key is no number.
  defp indexed(posted) when is_list(posted), do: Enum.with_index(posted, &{&2, &1})

  defp indexed(posted) do
    # Sorted by key as text first, so two keys for one index (`"01"` and
    # `"1"`) come in one order however large the map is.
    entries =
      posted
      |> Enum.sort_by(&to_string(elem(&1, 0)))
      |> Enum.map(fn {key, row} -> {integer_key(key), row} end)

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

  defp add_row(rows, at), do: List.insert_at(rows, add_index(at), {nil, %{}})

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
  # and under every field holding a value it does not offer, on the root form
  # or a sub-form the state takes, or `:ok` when there is none. A sub-form's
  # error is put on that sub-form, found by its name.
  #
  # A value is not offered when the field's narrowed `options/3` leave it
  # out, or, for a picker of records, when the read the picker searches
  # through does not find it: the lookup action with the field's
  # `lookup_args/3`, the relationship's own filters and the field's
  # `filter/3`s, one read per field. A key the record already holds is not
  # read unless the hook narrows the field, so a save that leaves a picker as
  # it was reads nothing; an inactive record it holds stays offered.
  def enforce(%FormState{} = state, form) do
    case required_errors(state) ++ offer_errors(state) do
      [] -> :ok
      errors -> {:error, %{put_errors(form, errors) | errors: true, submitted_once?: true}}
    end
  end

  defp required_errors(state) do
    for held <- [state | FormState.taken_sub_forms(state)],
        field <- FormState.blank_required(held),
        do: {held.form.name, field, required_error(field, held.form)}
  end

  defp offer_errors(state) do
    for held <- [state | FormState.taken_sub_forms(state)],
        %{hidden?: false, disabled?: false} = field <- held.fields,
        drawn_by_ash_quick?(field) or FormState.narrowed?(field),
        not_offered?(held, field),
        do: {held.form.name, field, not_offered_error(field)}
  end

  # A field a widget or a type's form input (`AshQuick.FormInput`) draws is
  # the host's: it offers what it likes, and its destination need have no
  # lookup action (`QuickViewOptions` asks none of it). It is held to what
  # it offers only when the hook narrows it, which needs the lookup action.
  defp drawn_by_ash_quick?(%{kind: :widget}), do: false
  defp drawn_by_ash_quick?(field), do: not AshQuick.FormInput.named?(field.source)

  defp not_offered?(state, %{options: options} = field) when is_list(options) do
    kept = MapSet.new(options, &to_string/1)

    state
    |> FormState.value(field.name)
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.any?(&(not MapSet.member?(kept, to_string(&1))))
  end

  defp not_offered?(state, field) do
    case FormState.relationship(state, field) do
      nil -> false
      relationship -> not_offered_record?(state, field, relationship)
    end
  end

  defp not_offered_record?(state, field, relationship) do
    key = record_key(state, field, relationship)
    kept = stored_keys(state.record, field, relationship, key)
    narrowing = FormRecords.narrowing(field)

    values =
      state
      |> FormState.value(field.name)
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, ""]))

    # Compared as text here, which may count a key held in another case as
    # new: the read then finds it, under the type's own comparison.
    checked =
      if narrowing,
        do: values,
        else: Enum.reject(values, &(to_string(&1) in kept))

    checked != [] and
      FormRecords.not_offered(
        relationship,
        key,
        checked,
        state.scope,
        narrowing,
        kept,
        created(state, field, relationship)
      ) != []
  end

  # A list of text whose change creates what matches no record: a value no
  # record holds is new, and the action decides whether it may make it.
  defp created(state, %{source: %Ash.Resource.Actions.Argument{} = argument}, relationship),
    do: Utils.created_values(argument, relationship, state.action.name)

  defp created(_state, _field, _relationship), do: nil

  defp record_key(_state, %{source: %BelongsTo{destination_attribute: key}}, _relationship),
    do: key

  defp record_key(state, field, relationship),
    do: Utils.list_key(field.source, relationship, state.action.name)

  defp stored_keys(nil, _field, _relationship, _key), do: []

  defp stored_keys(record, %{source: %BelongsTo{source_attribute: attribute}}, _rel, _key) do
    case Map.get(record, attribute) do
      nil -> []
      value -> [to_string(value)]
    end
  end

  # A many-to-many the record was read without counts as holding nothing,
  # so its keys are read back as new ones. The root's record is read with
  # its relationships; a stored row of a sub-form may not be.
  defp stored_keys(record, _field, relationship, key) do
    if Ash.Resource.loaded?(record, relationship.name),
      do:
        record
        |> Map.fetch!(relationship.name)
        |> List.wrap()
        |> Enum.map(&to_string(Map.get(&1, key))),
      else: []
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

  defp not_offered_error(%{inputs: [input | _], source: source}) do
    case source do
      %Ash.Resource.Actions.Argument{} ->
        Ash.Error.Changes.InvalidArgument.exception(field: input, message: @not_offered)

      _attribute_or_relationship ->
        Ash.Error.Changes.InvalidAttribute.exception(field: input, message: @not_offered)
    end
  end

  # Once a save was refused, a change keeps the error under a field
  # `require/3` marks that is still blank, as Ash keeps its own: validating
  # again would drop the one `enforce/2` added. Only shown, never refused on.
  # A value not offered is asked of the database, so only at the save.
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
