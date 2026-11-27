defmodule AshQuick.LiveView.FormParams do
  @moduledoc false
  # How a form's params are shaped on their way into AshPhoenix: nested and
  # embedded sub-forms, blank secrets, emptied selections and list arguments.
  alias AshQuick.LiveView.Digits
  alias AshQuick.LiveView.EnumOptions
  alias AshQuick.LiveView.FormInputs
  alias AshQuick.LiveView.Utils
  alias Ash.Resource.Actions.Argument
  alias Ash.Type

  @doc false
  def transform_nested_params(form, params, _) do
    form
    |> keep_blank_secrets(params)
    |> normalize_digits(form.resource, form.action)
    |> transform_nested_form_params(form)
  end

  # `params` with the numbers typed into the inputs of `action` that hold one
  # read the way Ash reads a number: trimmed, the digits an Arabic or Persian
  # keyboard types and its separators as ASCII (`Digits.normalize/1`), and,
  # on a field that takes a fraction or a `Money`'s amount
  # (`AshQuick.FormInput.Money`), a decimal comma as a point. A phone's
  # decimal pad in a comma locale offers only ",". The comma is read so only
  # where it is the only separator and is not followed by exactly three
  # digits: `1,000` could be a thousand, and is left as typed rather than
  # read as one point nought. Ash refuses it for a float or decimal; ex_money
  # reads a Money's as the thousand. Other inputs keep what was typed.
  @doc false
  def normalize_digits(params, resource, action) when is_map(params) do
    case action && action(resource, action) do
      nil ->
        params

      action ->
        action
        |> numeric_inputs(resource)
        |> Enum.reduce(params, &normalize_digits_at/2)
    end
  end

  def normalize_digits(params, _resource, _action), do: params

  defp action(resource, action) when is_atom(action),
    do: Ash.Resource.Info.action(resource, action)

  defp action(_resource, %{arguments: _} = action), do: action
  defp action(_resource, _action), do: nil

  defp normalize_digits_at({name, kind}, params) do
    case Map.fetch(params, name) do
      {:ok, %{"amount" => amount} = money} when kind == :money and is_binary(amount) ->
        Map.put(params, name, Map.put(money, "amount", typed_number(amount, :fraction)))

      {:ok, value} when is_binary(value) and kind != :money ->
        Map.put(params, name, typed_number(value, kind))

      _ ->
        params
    end
  end

  defp typed_number(value, kind) do
    value = value |> String.trim() |> Digits.normalize()

    if kind == :fraction and Regex.match?(~r/\A-?\d+,(\d{1,2}|\d{4,})\z/, value),
      do: String.replace(value, ",", "."),
      else: value
  end

  defp numeric_inputs(action, resource) do
    attributes =
      for name <- Map.get(action, :accept, []),
          attribute = Ash.Resource.Info.attribute(resource, name),
          kind = FormInputs.number_kind(attribute),
          do: {to_string(name), kind}

    arguments =
      for argument <- action.arguments,
          kind = FormInputs.number_kind(argument),
          do: {to_string(argument.name), kind}

    attributes ++ arguments
  end

  # Each nested form's config in `forms` (and in those nested under it, built
  # now or by an `updater` when the sub-form is added) given a
  # `transform_params` that reads its numbers as `normalize_digits/3` does,
  # before the one it already has. AshPhoenix runs a nested form's
  # `transform_params` from its own config only, so the root form's
  # `transform_nested_params/3` never sees an embed's or a related record's
  # inputs.
  @doc false
  def with_nested_digits(forms) when is_list(forms) do
    Enum.map(forms, fn
      {key, opts} when is_atom(key) and key != :auto? and is_list(opts) ->
        {key, nested_digits(opts)}

      other ->
        other
    end)
  end

  def with_nested_digits(forms), do: forms

  defp nested_digits(opts) do
    opts
    |> Keyword.put(:transform_params, digits_first(opts[:transform_params]))
    |> Keyword.update(:forms, [], &with_nested_digits/1)
    |> wrap_updater()
  end

  defp wrap_updater(opts) do
    case opts[:updater] do
      updater when is_function(updater, 1) ->
        Keyword.put(opts, :updater, fn o -> nested_digits(updater.(o)) end)

      updater when is_function(updater, 3) ->
        Keyword.put(opts, :updater, fn o, data, params ->
          nested_digits(updater.(o, data, params))
        end)

      _ ->
        opts
    end
  end

  defp digits_first(transform) do
    fn form, params, type ->
      params = normalize_digits(params, form.resource, form.action)

      cond do
        is_function(transform, 3) -> transform.(form, params, type)
        is_function(transform, 2) -> transform.(params, type)
        true -> params
      end
    end
  end

  # The input for a `sensitive?` field never shows the stored value, so on an
  # update a blank one means "unchanged", not "clear it".
  defp keep_blank_secrets(%{type: :update, resource: resource, action: action}, params) do
    resource
    |> sensitive_inputs(action)
    |> Enum.reduce(params, fn name, acc ->
      key = to_string(name)
      if Map.get(acc, key) == "", do: Map.delete(acc, key), else: acc
    end)
  end

  defp keep_blank_secrets(_form, params), do: params

  defp sensitive_inputs(resource, action) do
    case Ash.Resource.Info.action(resource, action) do
      nil ->
        []

      action ->
        accepted =
          for name <- action.accept,
              AshQuick.Info.sensitive?(resource, name),
              do: name

        accepted ++ for(%{sensitive?: true, name: name} <- action.arguments, do: name)
    end
  end

  # A list sub-form is left as AshPhoenix gives it: `[]` when the form counts
  # it as touched and it holds no rows, and nothing when it is untouched. An
  # untouched list is one the post left alone, or one the state holds back
  # (`AshQuick.LiveView.FormStateFlow` untouches it), so Ash never sees its
  # argument and an update keeps the record's rows.
  defp transform_nested_form_params(params, form) do
    for {name, opts} <- form.form_keys, opts[:type] == :single, reduce: params do
      params -> handle_empty_nested(params, to_string(name))
    end
  end

  defp handle_empty_nested(params, field_name) when is_binary(field_name) do
    case Map.get(params, field_name) do
      %{"_form_type" => _, "_persistent_id" => _} = param_value ->
        param_value =
          param_value
          |> Map.drop(["_form_type", "_persistent_id", "_touched"])

        if param_value |> Map.values() |> Enum.any?(&(&1 != "")) do
          params
        else
          params |> Map.put(field_name |> to_string(), nil)
        end

      _ ->
        params
    end
  end

  # Each list argument the form takes over a relationship, filled with the
  # ids of the records the relationship holds. The params it validates with
  # restate the embeds drawn as sub-forms (`carry_embedded_params/2`): they
  # start from the form's own, which on a form just built name none.
  @doc false
  def prefill_form_has_many_args(form, socket) do
    AshPhoenix.Form.arguments(form)
    |> Enum.reduce(form, fn arg, form_acc ->
      prefill_form_has_many_arg(form_acc, socket.assigns.resource, arg)
    end)
  end

  defp prefill_form_has_many_arg(form, resource, arg) do
    with %{destination: _, name: name} = relationship <-
           Utils.argument_to_relationship(arg, resource, form.action),
         records when is_list(records) <- Map.get(form.data, name) do
      key = Utils.list_key(arg, relationship, form.action)
      value = Enum.map(records, &(&1 |> Map.fetch!(key) |> to_string()))

      AshPhoenix.Form.update_params(form, fn params ->
        params |> Map.put(arg.name, value) |> carry_embedded_params(form)
      end)
    else
      _ -> form
    end
  end

  # A change module on the action may seed an embedded attribute onto the
  # changeset before submission. AshPhoenix builds embedded sub-forms from the
  # loaded record (`changeset.data`), not from the change, so such a seeded
  # value is not reflected in the form. Re-seed those sub-forms from the
  # changeset's current value via params: this leaves `changeset.data` untouched
  # (so anything captured from it on submit stays correct), and a real upload
  # still overrides the prefilled value. Scalar fields already prefill because
  # their value resolves through the changeset's changes.
  # `carried` is merged under the seeded values, so re-seeding keeps whatever the
  # caller has already typed. It is empty when the form is first built, which is
  # the only point at which there is nothing to keep.
  @doc false
  def prefill_changed_embedded_forms(form, carried \\ %{}) do
    seeded =
      form.form_keys
      |> Enum.flat_map(fn {field, config} ->
        case embedded_change_params(form.source, field, config[:type]) do
          :no_change -> []
          {:ok, params} -> [{field |> to_string(), params}]
        end
      end)
      |> Map.new()

    if map_size(seeded) == 0 do
      form
    else
      AshPhoenix.Form.validate(form, Map.merge(carried, seeded), errors: false)
    end
  end

  defp embedded_change_params(%Ash.Changeset{} = changeset, field, type)
       when type in [:list, :single] do
    with {:ok, value} <- Map.fetch(changeset.attributes, field),
         %{type: attr_type} <- Ash.Resource.Info.attribute(changeset.resource, field),
         true <- Ash.Type.embedded_type?(attr_type) do
      {:ok, embedded_to_params(value)}
    else
      _ -> :no_change
    end
  end

  defp embedded_change_params(_changeset, _field, _type), do: :no_change

  # An embed's value as the params a sub-form posts for it.
  @doc false
  def embedded_params(value), do: embedded_to_params(value)

  # One attribute's value as a sub-form posts it.
  @doc false
  def attribute_param(value, type), do: encode_embedded_value(value, type)

  defp embedded_to_params(values) when is_list(values) do
    Enum.map(values, &embedded_struct_to_params/1)
  end

  defp embedded_to_params(value), do: embedded_struct_to_params(value)

  defp embedded_struct_to_params(nil), do: %{}

  defp embedded_struct_to_params(%resource{} = struct) do
    Ash.Resource.Info.public_attributes(resource)
    |> Map.new(fn attr ->
      {attr.name |> to_string(), encode_embedded_value(Map.get(struct, attr.name), attr.type)}
    end)
  end

  # Attachment values are carried through the form as the JSON the upload
  # widget's hidden input submits, so a prefilled attachment round-trips on
  # save exactly like a freshly-uploaded one.
  defp encode_embedded_value(nil, _type), do: nil

  defp encode_embedded_value(%AshQuick.AshTypes.Attachment.Value{} = value, _type) do
    Jason.encode!(value)
  end

  defp encode_embedded_value(values, {:array, AshQuick.AshTypes.Attachment})
       when is_list(values) do
    Enum.map(values, &Jason.encode!/1)
  end

  defp encode_embedded_value(value, type) do
    if Ash.Type.embedded_type?(type) do
      embedded_to_params(value)
    else
      value
    end
  end

  # Validating with params that omit an embedded field clears it, and the params
  # this fold starts from are whatever the caller last submitted — which on a
  # page nothing has changed yet is nothing at all. Every embedded field the
  # params do not restate is carried over from the changeset so the fold cannot
  # drop what is already there.
  @doc false
  def carry_embedded_params(params, form) do
    Enum.reduce(form.form_keys, params, fn {field, config}, acc ->
      key = field |> to_string()

      with false <- Map.has_key?(acc, key),
           true <- config[:type] in [:list, :single],
           %{type: attr_type} <- Ash.Resource.Info.attribute(form.resource, field),
           true <- Ash.Type.embedded_type?(attr_type) do
        value = Ash.Changeset.get_attribute(form.source, field)
        Map.put(acc, key, embedded_to_params(value))
      else
        _not_a_carried_embed -> acc
      end
    end)
  end

  # A multi-select emptied of its last pick posts no value under its name, only
  # a `<name>_empty_selection` marker (`AshQuick.LiveView.Picker` posts one, as
  # LiveSelect does). Read as absent, the field would fall back to the value the
  # record holds, and the select would redraw every stored pick. The marker is
  # the page saying the list is now empty, on the root form and on any sub-form.
  @empty_selection "_empty_selection"

  @doc false
  def put_emptied_selections(%{} = params) when not is_struct(params) do
    Enum.reduce(params, %{}, fn {key, value}, acc ->
      case String.split(key, @empty_selection) do
        [name, ""] when name != "" -> Map.put_new(acc, name, [])
        _other -> Map.put(acc, key, put_emptied_selections(value))
      end
    end)
  end

  def put_emptied_selections(value), do: value

  # A list argument left out of the post means "emptied", so it is put back
  # as `[]`: only for an argument the form handles, never one it leaves out
  # as hidden, which would then save over a value its reader never saw, and
  # never one in `held`, the names the form's state hides or disables, which
  # the page draws no input for either.
  @doc false
  def maybe_put_has_many(params, form, held \\ []) do
    form
    |> Utils.form_fields()
    |> Enum.reject(&(&1.name in held))
    |> Enum.filter(fn
      %Argument{type: {:array, item_type}} = argument ->
        item_type in [Type.UUID, Type.UUIDv7] or EnumOptions.kind(argument) == :array or
          match?(
            %Ash.Resource.Relationships.ManyToMany{},
            Utils.argument_to_relationship(argument, form.resource, form.action)
          )

      _ ->
        false
    end)
    |> Enum.reduce(params, fn arg, updated_params ->
      updated_params |> Map.put_new(arg.name |> to_string(), [])
    end)
  end
end
