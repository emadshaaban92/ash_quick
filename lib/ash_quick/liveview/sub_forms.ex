defmodule AshQuick.LiveView.SubForms do
  @moduledoc false
  # AshPhoenix decides which sub-forms a post holds: a posted row is matched
  # to a sub-form the form holds, by its primary key when it posts the whole
  # of it and by its place otherwise; one that matches none is a new row, and
  # a sub-form no row matches is gone. `validate/3` is AshPhoenix's validate
  # with three gaps of that matching closed.
  #
  #   * A row is never matched to a sub-form of another type. AshPhoenix
  #     posts each row's type (`_form_type`) and does not read it back, so a
  #     row added on the page (`create`) would take the stored row
  #     (`update`) at its place: after a stored row was removed, one added
  #     and the view reconnected, the added row would save over the removed
  #     one.
  #   * A stored row posting part of its key is matched by that part
  #     (`same_row?/5`).
  #   * Every sub-form is named for where it ends up. AshPhoenix renames a
  #     row it matches at another place, but not the sub-forms under it, so
  #     their inputs would be drawn under the row's old name.
  #
  # A single sub-form posted as text (`""`), which no page posts, is left
  # out: AshPhoenix raises on it.

  @doc false
  def validate(form, params, opts \\ []) do
    form
    |> AshPhoenix.Form.validate(
      mapped(params, form_keys(form)),
      Keyword.put_new(opts, :matcher, &matches?/5)
    )
    |> named()
  end

  defp form_keys(%Phoenix.HTML.Form{source: source}), do: source.form_keys
  defp form_keys(form), do: form.form_keys

  defp mapped(params, form_keys) when is_map(params) and not is_struct(params) do
    Enum.reduce(form_keys, params, fn {key, opts}, params ->
      name = to_string(opts[:as] || key)
      mapped_under(params, name, opts[:type], opts[:forms] || [])
    end)
  end

  defp mapped(params, _form_keys), do: params

  defp mapped_under(params, name, type, form_keys) do
    case {type, Map.get(params, name)} do
      {:list, %{} = rows} when not is_struct(rows) ->
        Map.put(params, name, Map.new(rows, fn {at, row} -> {at, mapped(row, form_keys)} end))

      {:list, _rows} ->
        params

      {_single, text} when is_binary(text) ->
        Map.delete(params, name)

      {_single, %{} = row} when not is_struct(row) ->
        Map.put(params, name, mapped(row, form_keys))

      _other ->
        params
    end
  end

  @doc false
  def matches?(sub_form, params, parent, key, index) when is_map(params) do
    same_type?(sub_form, params) and same_row?(sub_form, params, parent, key, index)
  end

  def matches?(_sub_form, _params, _parent, _key, _index), do: false

  defp same_type?(sub_form, params),
    do: Map.get(params, "_form_type", to_string(sub_form.type)) == to_string(sub_form.type)

  # AshPhoenix's own rule, by the whole key or else by place, with one more
  # case between the two. A stored row whose key holds a field its sub-form
  # does not post, as the parent's id is when it is private, posts part of
  # its key. By place it would take another stored row once one above it was
  # removed and the view reconnected. So it is matched by the key fields it
  # does post, when they single out one of the stored rows.
  defp same_row?(sub_form, params, parent, key, index) do
    keys = Ash.Resource.Info.primary_key(sub_form.resource)

    case Enum.filter(keys, &Map.has_key?(params, to_string(&1))) do
      [] ->
        same_place?(sub_form, parent, key, index)

      ^keys ->
        same_key?(sub_form, params, keys)

      posted ->
        case by_part(parent, key, params, posted) do
          {:ok, row} -> row.id == sub_form.id
          :none -> same_place?(sub_form, parent, key, index)
        end
    end
  end

  # The one stored row holding the key fields a row posts, when there is
  # just one.
  defp by_part(parent, key, params, posted) do
    case Enum.filter(stored(parent, key), &same_key?(&1, params, posted)) do
      [row] -> {:ok, row}
      _none_or_several -> :none
    end
  end

  defp same_place?(sub_form, parent, key, index),
    do: sub_form.id == "#{parent.id}_#{key}_#{index}"

  defp same_key?(sub_form, params, fields),
    do: Enum.all?(fields, &same_value?(sub_form, &1, Map.fetch!(params, to_string(&1))))

  defp stored(parent, key) do
    case parent.forms[key] do
      rows when is_list(rows) -> Enum.filter(rows, &(&1.type == :update))
      _single -> []
    end
  end

  defp same_value?(sub_form, field, posted) do
    held = AshPhoenix.Form.value(sub_form, field)
    posted == held or (String.Chars.impl_for(held) != nil and posted == to_string(held))
  end

  defp named(%Phoenix.HTML.Form{source: source} = form),
    do: source |> named() |> Phoenix.HTML.FormData.to_form(form.options)

  defp named(%AshPhoenix.Form{} = form) do
    forms =
      Map.new(form.forms || %{}, fn
        {key, rows} when is_list(rows) ->
          {key, rows |> Enum.with_index() |> Enum.map(&named_under(&1, form, key))}

        {key, %AshPhoenix.Form{} = row} ->
          {key, named(%{row | name: "#{form.name}[#{key}]", id: "#{form.id}_#{key}"})}

        other ->
          other
      end)

    %{form | forms: forms}
  end

  defp named_under({row, index}, form, key) do
    named(%{row | name: "#{form.name}[#{key}][#{index}]", id: "#{form.id}_#{key}_#{index}"})
  end
end
