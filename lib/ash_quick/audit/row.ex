defmodule AshQuick.Audit.Row do
  @moduledoc false
  # The audit row AshQuick writes for one `{changeset, record, changes}` triple,
  # and the field list `AshQuick.Audit.Verifier` holds a store to.
  #
  # Built here rather than by the host, because half of it is the library's own
  # answer and not a convention a project can be expected to reproduce:
  # `real_actor_id` and `ip` come off `AshQuick.Scope`'s provenance, which is
  # the only thing that knows an impersonated write names two people.
  #
  # `changes` is the one field a store may not have. It was added after the
  # others, and a host one migration behind still has to write rows — so it is
  # left out of `fields/0` (what the verifier holds a store to) and out of the
  # row entirely unless the store carries the column. `Ash.bulk_create` refuses
  # an input the action does not take, so "left out" has to mean absent rather
  # than nil.

  alias AshQuick.Audit.Declaration

  # Ash's own marker for a value it will not print (`Ash.Helpers.redact/1`), so
  # a redacted before/after reads the same as a redacted changeset.
  @redacted "**redacted**"

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

  def build({%Ash.Changeset{} = changeset, record, changes}, actor) do
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
    |> put_changes(changeset, changes)
  end

  # Only for a store that has somewhere to put it: an input the `:create` action
  # does not know is a refused batch, and a refused batch is a failed write.
  defp put_changes(row, changeset, changes) do
    store = Declaration.store(changeset.resource)

    if store && Ash.Resource.Info.attribute(store, :changes) do
      Map.put(row, :changes, changes)
    else
      row
    end
  end

  # What the write changed, keyed by attribute name — `from` and `to` as the
  # store would hold them.
  #
  # Called by `AshQuick.Audit.Change` *before* it redacts the changeset, because
  # a sensitive attribute that did not change must be left out and that question
  # can only be asked of the real values. `redacted` is the names whose values
  # are replaced once it has been asked; nothing else about them is read.
  #
  # Values come off `changeset.data` and `changeset.attributes` only. Nothing
  # here reads the result record or goes back to the data layer: the entry is
  # written inside the transaction of the write it describes, and a read there
  # is a read on every audited write forever.
  def changes(%Ash.Changeset{} = changeset, redacted) do
    attributes = Ash.Resource.Info.attributes(changeset.resource)
    read? = read?(changeset.data)

    case changeset.action.type do
      :create -> created(changeset, attributes, redacted)
      :update -> updated(changeset, attributes, redacted, read?)
      :destroy -> destroyed(changeset, attributes, redacted, read?)
    end
  end

  # A create has nothing to compare against, so every attribute the action set
  # is a `to` and there is no `from` to be unknown.
  #
  # The assignment is a comprehension filter rather than a binding — anything
  # `changeset.attributes` holds that the resource does not call an attribute is
  # dropped here rather than written as an entry about nothing.
  defp created(changeset, attributes, redacted) do
    for {name, new} <- changeset.attributes,
        attribute = find(attributes, name),
        into: %{},
        do: {name, %{to: value(attribute, new, redacted)}}
  end

  # The keys are the ones the action set: an attribute the write did not touch
  # has no before and after, whatever it happens to hold. `entry` filters as
  # above, which is how an attribute set to the value it already held leaves no
  # entry at all.
  defp updated(changeset, attributes, redacted, read?) do
    for {name, new} <- changeset.attributes,
        attribute = find(attributes, name),
        entry = update_entry(attribute, Map.get(changeset.data, name), new, redacted, read?),
        into: %{},
        do: {name, entry}
  end

  defp update_entry(attribute, old, new, redacted, read?) do
    cond do
      not known?(read?, old) ->
        %{from_unknown: true, to: value(attribute, new, redacted)}

      # Asked of the real values rather than of what is recorded, so a sensitive
      # attribute set to what it already held is left out rather than reported
      # as a change between two identical redactions.
      dump(attribute, old) == dump(attribute, new) ->
        nil

      true ->
        %{from: value(attribute, old, redacted), to: value(attribute, new, redacted)}
    end
  end

  # A destroy sets nothing, so the entry is the record as it stood — every
  # attribute rather than the ones some action named.
  defp destroyed(changeset, attributes, redacted, read?) do
    for attribute <- attributes, into: %{} do
      old = Map.get(changeset.data, attribute.name)

      if known?(read?, old) do
        {attribute.name, %{from: value(attribute, old, redacted)}}
      else
        {attribute.name, %{from_unknown: true}}
      end
    end
  end

  # Two ways a previous value is not there to record, and neither of them is
  # `nil`: a column the read did not select, and a record that was never read at
  # all. Ash hands back `%Ash.NotLoaded{}` for the first; for the second — a
  # hand-built `%Brand{id: id}` — every field simply holds its default, so a
  # `nil` there is evidence of nothing and `__meta__` is what says so. Both
  # AshPostgres and `Ash.DataLayer.Ets` stamp `:loaded` on what they return.
  defp read?(%{__meta__: %Ecto.Schema.Metadata{state: :loaded}}), do: true
  defp read?(_data), do: false

  defp known?(false, _old), do: false
  defp known?(true, %Ash.NotLoaded{}), do: false
  defp known?(true, _old), do: true

  # Only what `Ash.Resource.Info.attributes/1` names, so a relationship, a
  # calculation, an aggregate or `__metadata__` never reaches the entry.
  defp find(attributes, name), do: Enum.find(attributes, &(&1.name == name))

  # Redaction happens after the comparison and instead of the dump: a secret is
  # not a value to be recorded in any form, and the entry says only that it
  # changed.
  defp value(%{name: name} = attribute, value, redacted) do
    if name in redacted, do: @redacted, else: dump(attribute, value)
  end

  # The value as the store would hold it, applied identically to both sides so
  # the comparison is between like and like. A type that cannot dump — or that
  # raises trying — falls back to `storable/1`: a failed dump describes the
  # write badly, and failing the write over it would be worse.
  defp dump(%{type: type, constraints: constraints}, value) do
    case Ash.Type.dump_to_embedded(type, value, constraints) do
      {:ok, dumped} -> storable(dumped)
      _error -> storable(value)
    end
  rescue
    _error -> storable(value)
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
  #
  # `__meta__` goes with the struct it came off: an `Ecto.Schema.Metadata` is
  # the one field `@derive Jason.Encoder` refuses outright rather than encodes,
  # and an embedded resource in `changeset.attributes` — an attachment, a line
  # item — carries one.
  defp storable(%_struct{} = value) do
    if Jason.Encoder.impl_for(value) == Jason.Encoder.Any do
      value |> Map.from_struct() |> Map.delete(:__meta__) |> storable()
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
