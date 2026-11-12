defmodule AshQuick.ReadOnlyFields.StripReadOnlyFields do
  @moduledoc false
  use Ash.Resource.Change

  alias AshQuick.ReadOnlyFields.Check
  alias AshQuick.ReadOnlyFields.Info

  @recorded :ash_quick_read_only_left

  # Runs twice on every create, update and destroy the transformer saw.
  #
  # First (`stage: :action`), at the head of the action's own changes, so a
  # refused input is gone before any of them reads it (a `manage_relationship`
  # over an argument, a `set_attribute(:x, arg(:y))`). It notes, for each
  # refused attribute, what it left behind.
  #
  # Then (`stage: :global`), among the global changes, after the action's own.
  # There it leaves arguments alone: the first run already handled them, and
  # running again would resolve a function default a second time, so a change
  # that copied the first value would disagree with an `after_action` reading
  # the second. It clears a refused attribute only when one of the action's
  # changes moved it off what the first run left (filled it from another
  # input, or set it itself), and puts back what the first run left, not a
  # fresh default. It also registers a `before_action` that checks once more,
  # after the hooks the action's changes registered, so a hook that writes the
  # field is undone too. A global change listed after this one registers its
  # hooks later, and those are not undone.
  #
  # An action with no strip of its own (one another extension added after the
  # transformer ran) gets only the global run, which then strips in full; the
  # verifier refuses one whose own changes could read a refused input first.
  @impl true
  def change(changeset, opts, context), do: run(changeset, opts, context, true)

  # The same on the atomic path, less the `before_action` recheck: an atomic
  # write runs no `before_action` hook, the action's own included. An accepted
  # input arrives there in `changeset.atomics` rather than
  # `changeset.attributes`, and `Ash.Changeset.clear_change/2` clears both, so
  # a read-only value is dropped whichever path the write takes.
  @impl true
  def atomic(changeset, opts, context), do: {:ok, run(changeset, opts, context, false)}

  defp run(changeset, opts, context, hook?) do
    refused = refused_fields(changeset, context)
    hook = if hook?, do: refused, else: []

    cond do
      opts[:stage] != :global ->
        changeset |> strip(refused) |> record(refused)

      strips_itself?(changeset.action) ->
        changeset |> recheck(refused) |> recheck_before_action(hook)

      true ->
        changeset |> strip(refused) |> record(refused) |> recheck_before_action(hook)
    end
  end

  defp recheck_before_action(changeset, []), do: changeset

  # Registered wherever `change/3` runs, whatever `require_atomic?` says: an
  # atomic write goes through `atomic/3` instead, and a non-atomic one (a
  # `bulk_update` with `strategy: :stream`, say) runs the action's hooks.
  defp recheck_before_action(changeset, refused),
    do: Ash.Changeset.before_action(changeset, &recheck(&1, refused))

  defp refused_fields(changeset, context) do
    check_context = %Check.Context{actor: context.actor, tenant: context.tenant}

    changeset.resource
    |> Info.read_only_fields(changeset.action.name)
    |> Enum.reject(fn read_only -> Info.check_passes?(read_only.writable_if, check_context) end)
    |> Enum.map(& &1.field)
  end

  defp strip(changeset, refused) do
    Enum.reduce(refused, changeset, fn field, cs ->
      cs
      |> clear_attribute(field)
      |> clear_argument(field)
    end)
  end

  # Every refused field is written afresh, so nothing a caller put in the
  # context under this key survives for a field that matters.
  defp record(changeset, refused) do
    left = Map.new(refused, &{&1, attribute_state(changeset, &1)})
    previous = changeset.context[:private][@recorded] || %{}

    Ash.Changeset.set_context(changeset, %{private: %{@recorded => Map.merge(previous, left)}})
  end

  defp recheck(changeset, refused) do
    recorded = changeset.context[:private][@recorded] || %{}

    Enum.reduce(refused, changeset, fn field, cs ->
      case Map.fetch(recorded, field) do
        {:ok, left} -> restore_if_moved(cs, field, left)
        :error -> cs |> clear_attribute(field) |> clear_argument(field)
      end
    end)
  end

  # A create fills function defaults after the action's changes and before its
  # hooks, so the `before_action` run finds one the first run left unset. That
  # is Ash's default, not a write: it has not moved. (ETS fills them again on
  # insert, so a test there would not notice; Postgres inserts what is here.)
  defp restore_if_moved(changeset, field, {:error, :error, false} = left) do
    if field in changeset.defaults,
      do: changeset,
      else: restore_if_changed(changeset, field, left)
  end

  defp restore_if_moved(changeset, field, left),
    do: restore_if_changed(changeset, field, left)

  defp restore_if_changed(changeset, field, left) do
    if attribute_state(changeset, field) == left,
      do: changeset,
      else: restore(changeset, field, left)
  end

  # Whether the value is one of Ash's defaults matters as much as the value:
  # an upsert writes over the existing row only the attributes that are not.
  defp attribute_state(changeset, field) do
    {Map.fetch(changeset.attributes, field), Keyword.fetch(changeset.atomics, field),
     field in changeset.defaults}
  end

  defp restore(changeset, field, {attribute, atomic, default?}) do
    changeset = Ash.Changeset.clear_change(changeset, field)

    changeset =
      case attribute do
        {:ok, value} -> Ash.Changeset.force_change_attribute(changeset, field, value)
        :error -> changeset
      end

    changeset = if default?, do: mark_default(changeset, field), else: changeset

    case atomic do
      {:ok, expr} -> %{changeset | atomics: Keyword.put(changeset.atomics, field, expr)}
      :error -> changeset
    end
  end

  defp strips_itself?(action) do
    Enum.any?(action.changes, &match?(%{change: {__MODULE__, _}}, &1))
  end

  # A refused input acts as if it was never sent: what Ash would have done
  # without it still happens. A cleared attribute takes its default back (the
  # `default` on a create, the `update_default` on an update), a cleared
  # argument its `default`, and a required argument with no default is
  # reported missing, as Ash reports one that was left out.
  defp clear_attribute(changeset, field) do
    attribute = Ash.Resource.Info.attribute(changeset.resource, field)

    if attribute && Ash.Changeset.changing_attribute?(changeset, field) do
      changeset = Ash.Changeset.clear_change(changeset, field)

      case default_of(attribute, changeset.action_type) do
        nil ->
          changeset

        default ->
          changeset
          |> Ash.Changeset.force_change_attribute(field, resolve(default))
          |> mark_default(field)
      end
    else
      changeset
    end
  end

  defp clear_argument(changeset, field) do
    argument = Enum.find(changeset.action.arguments, &(&1.name == field))

    cond do
      not Map.has_key?(changeset.arguments, field) ->
        changeset

      is_nil(argument) ->
        %{changeset | arguments: Map.delete(changeset.arguments, field)}

      not is_nil(argument.default) ->
        %{changeset | arguments: Map.put(changeset.arguments, field, resolve(argument.default))}

      argument.allow_nil? == false and not is_nil(changeset.arguments[field]) ->
        %{changeset | arguments: Map.delete(changeset.arguments, field)}
        |> Ash.Changeset.add_error(
          Ash.Error.Changes.Required.exception(
            resource: changeset.resource,
            field: field,
            type: :argument
          )
        )

      true ->
        %{changeset | arguments: Map.delete(changeset.arguments, field)}
    end
  end

  # `force_change_attribute/3` takes the field out of `defaults`, so it would
  # read as a value the caller sent, and an upsert would write it over the
  # existing row. Marked again, it stays a default, as Ash sets it.
  defp mark_default(changeset, field) do
    %{changeset | defaults: Enum.uniq([field | changeset.defaults])}
  end

  defp default_of(attribute, :create), do: attribute.default
  defp default_of(attribute, :update), do: attribute.update_default
  defp default_of(_attribute, _type), do: nil

  defp resolve(default) when is_function(default, 0), do: default.()

  defp resolve({module, function, args}) when is_atom(module) and is_list(args),
    do: apply(module, function, args)

  defp resolve(default), do: default
end
