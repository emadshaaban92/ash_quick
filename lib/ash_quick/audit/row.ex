defmodule AshQuick.Audit.Row do
  @moduledoc false
  # The audit row AshQuick writes for one `{subject, record, changes}` triple,
  # and the field list `AshQuick.Audit.Verifier` holds a store to. The subject
  # is the changeset of a write or the query of an audited read: both carry the
  # resource, the action, its arguments, its context and the provenance, which
  # is all a row is made of. A read was given no attributes and changed nothing,
  # so its `attributes` and `changes` are empty.
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
  alias AshQuick.Audit.Expression

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

  def build({%struct{} = subject, record, changes}, actor)
      when struct in [Ash.Changeset, Ash.Query] do
    actor_id = actor_id(subject, actor)

    %{
      resource_name: Ash.Resource.Info.short_name(subject.resource),
      resource_id: resource_id(record.id),
      action_type: subject.action.type,
      action_name: subject.action.name,
      attributes: storable(attributes(subject)),
      arguments: storable(subject.arguments),
      context: context(subject),
      actor_id: actor_id,
      # Never `nil` while there is an actor: the two are simply equal unless
      # someone was impersonating. An action with no actor and no scope behind
      # it has neither, and both are `nil`.
      real_actor_id: id(AshQuick.Scope.real_actor(subject)) || actor_id,
      ip: AshQuick.Scope.ip(subject),
      tenant: subject.tenant
    }
    |> put_changes(subject, changes)
  end

  defp attributes(%Ash.Changeset{attributes: attributes}), do: attributes
  defp attributes(%Ash.Query{}), do: %{}

  # As text, so a `:string` column — what the installer generates — takes an
  # integer key as it takes a UUID, and a `:uuid` column still casts it back.
  defp resource_id(nil), do: nil
  defp resource_id(id) when is_binary(id), do: id
  defp resource_id(id), do: to_string(id)

  # What the action was given, as `changeset.attributes` holds it on the
  # in-memory path, so the row's `attributes` reads the same whichever path the
  # write took. Called by `AshQuick.Audit.Change` before it redacts, because
  # what an atomic is can only be asked of the real value.
  #
  # An atomic update holds what it sets in `changeset.atomics`, and three kinds
  # of entry live there:
  #
  #   * a plain value — an accepted input, or a change's `set_attribute` — which
  #     the in-memory path would have put in `changeset.attributes`;
  #   * an expression standing for an input or an update default: a type that
  #     casts an input atomically (`Ash.Type.cast_atomic/3`) can turn it into
  #     one, and `updated_at` is always one. The in-memory path records those as
  #     values, so their value is read off the record the write returned;
  #   * an expression a change asked for — `count + 1` — which is not input on
  #     either path. What it came to is in `changes`, with the expression.
  #
  # A value the write did not return (`%Ash.NotLoaded{}`) is left out rather
  # than recorded as that struct.
  def given(%Ash.Changeset{} = changeset, record) do
    Enum.reduce(changeset.atomics, changeset.attributes, fn {name, value}, given ->
      case given_value(changeset, record, name, value) do
        {:ok, value} -> Map.put(given, name, value)
        :error -> given
      end
    end)
  end

  defp given_value(changeset, record, name, value) do
    case kind(changeset, name, value) do
      :value -> {:ok, value}
      :given -> returned(record, name)
      :asked -> :error
    end
  end

  # Which of the three kinds above an atomic is. A versioned resource's counter
  # counts as an update default: the lock sets it by an expression on this path
  # and as a value in memory, and that expression repeats every other one the
  # write set, a sensitive one included.
  defp kind(changeset, name, value) do
    cond do
      not Ash.Expr.expr?(value) -> :value
      input?(changeset, name) or update_default?(changeset, name) -> :given
      name == AshQuick.Info.versioning_attribute(changeset.resource) -> :given
      true -> :asked
    end
  end

  defp input?(%{action: action, params: params}, name) do
    name in List.wrap(action.accept) and
      (Map.has_key?(params, name) or Map.has_key?(params, to_string(name)))
  end

  defp update_default?(%{resource: resource}, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      %{update_default: default} -> not is_nil(default)
      nil -> false
    end
  end

  defp returned(record, name) do
    case Map.get(record, name) do
      %Ash.NotLoaded{} -> :error
      value -> {:ok, value}
    end
  end

  # Only for a store that has somewhere to put it: an input the `:create` action
  # does not know is a refused batch, and a refused batch is a failed write.
  defp put_changes(row, subject, changes) do
    store = Declaration.store(subject.resource)

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
  # can only be asked of the real values. `redacted` and `arguments` are the
  # attribute and argument names whose values are replaced once it has been
  # asked; nothing else about them is read.
  #
  # `from` comes off `changeset.data` — or, for a destroy run as one query, off
  # the row it returned (`stood/2`) — and `to` off what the write set
  # (`written/2`). Nothing here goes back to the data layer: the entry is
  # written inside the transaction of the write it describes, and a read there
  # is a read on every audited write forever.
  def changes(%Ash.Changeset{} = changeset, record, redacted, arguments) do
    attributes = Ash.Resource.Info.attributes(changeset.resource)
    written = written(changeset, record)

    case changeset.action.type do
      :create ->
        created(written, attributes, redacted)

      :update ->
        changeset
        |> updated(written, attributes, redacted, read?(changeset.data))
        |> put_expressions(changeset, attributes, redacted, arguments)

      :destroy ->
        destroyed(stood(changeset, record), attributes, redacted)
    end
  end

  # What the write set, keyed by attribute name. A value set in memory is in
  # `changeset.attributes`. One set atomically is in `changeset.atomics`, and is
  # either a value or an expression only the data layer evaluated, so what it
  # came to is read off the record the write returned — the one place it is
  # known without a read. Every update goes this way when it runs atomically,
  # and an `atomic_update` change sends its attribute this way on any path.
  defp written(changeset, record) do
    for {name, _value} <- changeset.atomics,
        into: changeset.attributes,
        do: {name, Map.get(record, name)}
  end

  # A create has nothing to compare against, so every attribute the action set
  # is a `to` and there is no `from` to be unknown.
  #
  # The assignment is a comprehension filter rather than a binding — anything
  # the write set that the resource does not call an attribute is dropped here
  # rather than written as an entry about nothing.
  defp created(written, attributes, redacted) do
    for {name, new} <- written,
        attribute = find(attributes, name),
        into: %{},
        do: {name, to_entry(attribute, new, redacted)}
  end

  # The keys are the ones the action set: an attribute the write did not touch
  # has no before and after, whatever it happens to hold. `entry` filters as
  # above, which is how an attribute set to the value it already held leaves no
  # entry at all.
  defp updated(changeset, written, attributes, redacted, read?) do
    for {name, new} <- written,
        attribute = find(attributes, name),
        entry = update_entry(attribute, Map.get(changeset.data, name), new, redacted, read?),
        into: %{},
        do: {name, entry}
  end

  defp update_entry(attribute, old, new, redacted, read?) do
    cond do
      not known?(read?, old) ->
        Map.put(to_entry(attribute, new, redacted), :from_unknown, true)

      not known?(true, new) ->
        %{from: value(attribute, old, redacted), to_unknown: true}

      # Asked of the real values rather than of what is recorded, so a sensitive
      # attribute set to what it already held is left out rather than reported
      # as a change between two identical redactions.
      dump(attribute, old) == dump(attribute, new) ->
        nil

      true ->
        %{from: value(attribute, old, redacted), to: value(attribute, new, redacted)}
    end
  end

  # An attribute a change set by an expression keeps it as `expr`, beside the
  # `from` and `to` it came to, which stays true even where `from` is stale.
  # Only the third kind in `given/2`: an input, an update default or the lock's
  # counter is a value on the in-memory path, and `now()` on every entry would
  # say nothing.
  #
  # Secrets are worked out only when there is an expression to keep them from.
  defp put_expressions(entries, changeset, attributes, redacted, arguments) do
    asked =
      for {name, value} <- changeset.atomics,
          Map.has_key?(entries, name),
          kind(changeset, name, value) == :asked,
          do: name

    if asked == [] do
      entries
    else
      secrets = Expression.secrets(changeset, redacted, arguments)

      Enum.reduce(asked, entries, fn name, entries ->
        text = expression(changeset, find(attributes, name), attributes, redacted, secrets)
        Map.update!(entries, name, &Map.put(&1, :expr, text))
      end)
    end
  end

  defp expression(changeset, %{name: name} = attribute, attributes, redacted, secrets) do
    if name in redacted do
      @redacted
    else
      changeset
      |> Expression.expression(name)
      |> Expression.render(attribute, attributes, secrets)
    end
  end

  # The new value mirrors the old: one the write set atomically is read off the
  # record it returned, and a `select` can leave it out of that record, which
  # says nothing about what it now holds.
  defp to_entry(attribute, new, redacted) do
    if known?(true, new),
      do: %{to: value(attribute, new, redacted)},
      else: %{to_unknown: true}
  end

  # The record a destroy removed. Usually that is the one the actor loaded. A
  # bulk destroy run as one query loads none — Ash marks its data
  # `OriginalDataNotAvailable` — but the rows its `DELETE ... RETURNING` handed
  # back are exactly the rows as they stood, so those are read instead. Only
  # then: elsewhere the returned record may be the data handed in, and a
  # hand-built `%Brand{id: id}` coming back would read as a record of nils.
  defp stood(%{data: %Ash.Changeset.OriginalDataNotAvailable{}}, record), do: record
  defp stood(changeset, _record), do: changeset.data

  # A destroy sets nothing, so the entry is the record as it stood — every
  # attribute rather than the ones some action named.
  defp destroyed(stood, attributes, redacted) do
    read? = read?(stood)

    for attribute <- attributes, into: %{} do
      old = Map.get(stood, attribute.name)

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
  # this row names. No actor at all is a write nobody was behind, and the row
  # says so with `nil`. Anything else is an actor that cannot be named, and an
  # entry that says nobody did it when somebody did is worse than the write
  # failing here: that is the record somebody will come looking for.
  defp actor_id(_subject, nil), do: nil

  defp actor_id(subject, actor) do
    case id(actor) do
      nil -> raise AshQuick.Audit.ActorError, resource: subject.resource, actor: actor
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

  # Only the keys that were asked for. A context holds whatever any part of the
  # pipeline put there — Ash's own bookkeeping, and anything an action carries
  # between its own hooks, such as the bytes of a file it is about to hand back
  # — and none of that was meant for a table that is never rotated. So nothing
  # is kept because of what it is: `action_source`, which every QuickView
  # stamps and which says which surface wrote, and the keys the resource lists
  # in `record_context`. A listed key holding anything but an atom or a string
  # is dropped rather than flattened, since no one listed what is inside it.
  defp context(%{resource: resource, context: %{} = context}) do
    for key <- Enum.uniq([:action_source | Declaration.record_context(resource)]),
        {:ok, value} <- [Map.fetch(context, key)],
        is_atom(value) or is_binary(value),
        into: %{},
        do: {key, value}
  end

  defp context(_subject), do: %{}
end
