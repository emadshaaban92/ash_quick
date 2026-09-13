defmodule AshQuick.Audit.Row do
  @moduledoc false
  # The audit row AshQuick writes for one `{changeset, record}` pair, and the
  # field list `AshQuick.Audit.Verifier` holds a store to.
  #
  # Built here rather than by the host, because half of it is the library's own
  # answer and not a convention a project can be expected to reproduce:
  # `real_actor_id` and `ip` come off `AshQuick.Scope`'s provenance, which is
  # the only thing that knows an impersonated write names two people.

  @fields [
    :resource_name,
    :resource_id,
    :action_type,
    :action_name,
    :attributes,
    :arguments,
    :context,
    :actor_id,
    :real_actor_id,
    :ip,
    :tenant
  ]

  def fields, do: @fields

  def build({%Ash.Changeset{} = changeset, record}, actor) do
    actor_id = actor_id(changeset, actor)

    %{
      resource_name: Ash.Resource.Info.short_name(changeset.resource),
      resource_id: record.id,
      action_type: changeset.action.type,
      action_name: changeset.action.name,
      attributes: storable(changeset.attributes),
      arguments: storable(changeset.arguments),
      context: simple_context(changeset.context),
      actor_id: actor_id,
      # Never `nil` while there is an actor: the two are simply equal unless
      # someone was impersonating.
      real_actor_id: id(AshQuick.Scope.real_actor(changeset)) || actor_id,
      ip: AshQuick.Scope.ip(changeset),
      tenant: changeset.tenant
    }
  end

  # Ash takes any term as an actor, and a caller that already holds the id
  # passes that rather than reading the record back — so both are the actor
  # this row names. Anything else cannot be named, and an entry that says
  # nobody did it is worse than the write failing here: that is the record
  # somebody will come looking for.
  defp actor_id(changeset, actor) do
    case id(actor) do
      nil -> raise AshQuick.Audit.ActorError, resource: changeset.resource, actor: actor
      id -> id
    end
  end

  defp id(%{id: id}), do: id
  defp id(id) when is_binary(id) or is_integer(id), do: id
  defp id(_actor), do: nil

  # A store column is JSON, and an action's inputs are Elixir. A tuple is the
  # one everyday term with no JSON of its own — an `{:ok, value}` verdict, a
  # `{module, opts}` pair — and it arrives as the list it already is rather
  # than failing the write it describes. The rest are terms that only mean
  # anything in the process that made them.
  #
  # A struct is kept whole when it knows how to encode itself — a `Money`, a
  # `DateTime`, a resource record — and flattened to its fields when it does
  # not, which is what `@derive Jason.Encoder` would have written. An argument
  # holding a plain struct is ordinary Elixir, and the entry describing the
  # write must not be what fails it.
  defp storable(%_struct{} = value) do
    if Jason.Encoder.impl_for(value) == Jason.Encoder.Any do
      value |> Map.from_struct() |> storable()
    else
      value
    end
  end

  defp storable(%{} = value), do: Map.new(value, fn {key, value} -> {key, storable(value)} end)

  defp storable(value) when is_list(value), do: Enum.map(value, &storable/1)

  defp storable(value) when is_tuple(value), do: value |> Tuple.to_list() |> storable()

  defp storable(value) when is_pid(value) or is_reference(value) or is_function(value),
    do: inspect(value)

  defp storable(value), do: value

  # A context holds whatever any part of the pipeline put there, including
  # structs and pids that no column could take. The flat scalars are the part
  # worth keeping — `action_source` above all, which says which surface wrote.
  defp simple_context(%{} = context) do
    context
    |> Enum.filter(fn {_k, v} -> is_atom(v) or is_binary(v) end)
    |> Enum.into(%{})
  end

  defp simple_context(_context), do: %{}
end
