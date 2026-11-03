defmodule AshQuick.Audit.Change do
  @moduledoc """
  Hands a batch of writes to the resource's `AshQuick.Audit.Store`.

  Attached to every create, update and destroy of a resource carrying the
  AshQuick extension, since auditing is on unless a resource turns it off —
  see `AshQuick.Audit.Transformer` for the two it is never attached to. A
  resource that turns it off at resource level and wants only some of its
  actions audited attaches it to those by hand.

  Every audited write is recorded, including one with no actor — a background
  job, a scheduled task, an integration. Its row has `actor_id: nil`, which says
  that nobody was behind it rather than leaving no trace that it happened.

  To say *what* made a write, name it under `action_source` in the action's
  context — `context: %{action_source: "nightly_sync"}` — and it is kept in the
  row's `context`. That is a convention rather than a requirement: nothing
  refuses a write without one. It is worth setting on any write a person did not
  make through a form, with an actor or without, because one key across a host
  is one filter across its log. Any other top-level string or atom value in the
  context is kept too; a nested value is not.

  There are two ways to keep a write out of the log: name its action in
  `exclude_actions`, or turn auditing off for the resource. Passing no actor is
  not one of them.

  An action named in `exclude_actions` records nothing — for one that
  authorizes and emits but writes nothing, where a row per record would say a
  change happened that did not. Excluding is per resource and per action, so
  the next one is a deliberate addition rather than something a broad rule
  swallows.

  Nothing is filtered on how *much* a changeset changed, and in particular an
  empty one is still recorded. An action that writes no attribute is not an
  action that did nothing: an `:impersonate` action on a user resource can
  accept no input and manually return its record unchanged, so the
  authorization check and the entry naming who ran it are the whole point of
  the action. A rule
  keyed on an empty changeset would silence exactly those.

  ## What changed

  `attributes` and `arguments` record what the action was *given*. `changes`
  records what the values *were*: a map keyed by attribute name, holding `from`
  and `to` for a create or an update, and a `from` snapshot of the whole record
  for a destroy. An attribute the write set to the value it already held is left
  out, so the map is what changed rather than what was submitted — an edit form
  posts every field.

  The column is optional. A store without a `changes` attribute records rows
  exactly as it always did, and an existing host opts in by adding the attribute
  to its store and running `mix ash.codegen`:

      attribute :changes, :map, allow_nil?: false, default: %{}, public?: true

  `from` is read off the record the actor loaded — `changeset.data` — and never
  from a fresh read: the entry is written inside the transaction of the write it
  describes, and a read there is a read on every audited write forever. So on an
  unversioned resource `from` is what that actor last saw, which another write
  may already have replaced. On a versioned one the optimistic lock rules that
  out, except for the attributes named in `versioning_ignored_attributes`, which
  are by definition allowed to move underneath a held record.

  A previous value that is not known is written as `from_unknown: true` and
  never as `from: nil` — `nil` is a value a column can hold, and saying a field
  had been blank is a different claim from not knowing what it held. There are
  three ways to reach it: an attribute the read did not `select`, a record that
  was never read at all, such as a hand-built `%Brand{id: id}`, and a bulk
  update run as one query, which never reads its rows. A bulk destroy run as
  one query reads none either, but the rows it deleted come back from the data
  layer as they stood, and `from` is read off those.

  ## Atomic writes

  An update or destroy that keeps Ash's default `require_atomic? true` runs
  atomically, and the entry is written for it all the same. Such an update
  holds what it sets in `changeset.atomics` rather than in
  `changeset.attributes`, as a value or as an expression only the data layer
  evaluates. `to` is read off the record the write returned — the one place
  the new value is known without a read. That holds on any path, so an
  `atomic_update` on a non-atomic action is recorded too. A new value the
  record does not hold, because a `select` left it out, is written as
  `to_unknown: true`, the way an unknown previous value is.

  The entry's `attributes` read the same whichever path the write took: an
  accepted input and an update default such as `updated_at` are kept (and
  redacted) as values, even where Ash turned them into an expression, and an
  `atomic_update` a change asked for, such as `count + 1`, is not input on
  either path.

  On an unversioned resource `from` is still what the actor loaded, so two
  `count + 1` writes at once can leave an entry reading `from: 0, to: 2`.

  On a versioned resource the optimistic lock refuses a write against a stale
  copy on this path too, so `from` there is what the row held.

  Only attributes appear. A `has_many` or `many_to_many` change is not one — it
  is a write to the other resource, recorded in that resource's own entries, and
  visible here in `arguments` as the input the action was given. An embedded
  resource *is* an attribute, and is recorded whole on both sides.

  Values are dumped the way the store would hold them, so a `Money` or an array
  of embedded resources reads back as JSON rather than as an inspected struct.

  ## Secrets

  A `sensitive?` attribute or argument is replaced with `"**redacted**"` in the
  changeset's attributes, arguments and params before the batch leaves here.
  Redacting before the row is built is what makes it a property of auditing
  itself: the first resource with a password argument does not write plaintext
  into a table that is never rotated and is readable by everyone with audit
  access. It is the changeset that is redacted rather than the row, so anything
  else handed the batch is handed the redacted one too.

  What that covers is a value the write does not *store* — a password hashed
  before the column, a token exchanged for something else. Those three fields
  are the only copy of such a value, so redacting them is what makes it
  unreachable whichever one the row is built from.

  A value the write *does* store is a different matter. `changeset.data` and the
  result record are handed over as they are: they are typed structs, and
  `"**redacted**"` is not a `Money` or a `:utc_datetime` — which is why Ash
  redacts a record when inspecting it and never in the data itself. The value
  sits in the resource's own column regardless, so a store column copying whole
  records is choosing to duplicate it rather than being handed it by surprise.

  `changes` is redacted the same way, on both sides: a sensitive attribute not
  named in `record_sensitive` reads `%{from: "**redacted**", to: "**redacted**"}`
  rather than either value. Whether it changed at all is still asked of the real
  values, which is why the map is worked out before the changeset is redacted —
  a secret rotated to what it already held leaves no entry, and one that really
  changed is not hidden behind two identical redactions.

  Redaction is flat. A sensitive attribute nested inside an embedded resource,
  or inside a managed relationship's params, is not reached.

  A value the host wants recorded despite the flag is named in
  `record_sensitive`, which is per resource:

      audit do
        record_sensitive [:masked_card_number]
      end
  """

  use Ash.Resource.Change

  require Ash.Tracer

  alias AshQuick.Audit.Declaration
  alias AshQuick.Audit.Row
  alias AshQuick.Audit.Store

  # Ash's own marker for a value it will not print (`Ash.Helpers.redact/1`), so
  # a redacted entry reads the same as a redacted changeset.
  @redacted "**redacted**"

  @impl true
  def batch_change(changesets, _opts, _context) do
    changesets
  end

  # Nothing to add to the write itself: the entry is built in `after_batch/3`,
  # which Ash runs on the atomic path too, handing it the record the write
  # returned. So an audited action needs no `require_atomic? false` of its own.
  @impl true
  def atomic(changeset, _opts, _context), do: {:ok, changeset}

  @impl true
  def after_batch([{changeset, _record} | _] = changesets_and_results, _opts, context) do
    if excluded?(changeset) do
      :ok
    else
      Ash.Tracer.span :custom, "Audit Log", changeset.context[:private][:tracer] do
        log(changesets_and_results, context.actor)
      end
    end
  end

  # A bulk update whose every changeset failed reaches here with nothing left.
  def after_batch([], _opts, _context), do: :ok

  defp excluded?(%Ash.Changeset{resource: resource, action: %{name: name}}) do
    name in Declaration.exclude_actions(resource)
  end

  # Every changeset in a batch is the same action on the same resource, so what
  # has to be stamped out is worked out once rather than per record.
  defp log([{changeset, _record} | _] = changes, actor) do
    {attributes, arguments} = to_redact(changeset)

    changes
    |> Enum.map(&entry(&1, attributes, arguments))
    |> Store.write(actor)
  end

  # `changes` is worked out first, against the changeset as the action left it:
  # whether a sensitive attribute changed at all is a question about the real
  # values, and one line further down they are gone. `AshQuick.Audit.Row` is
  # handed the names to redact so it answers that question before it records
  # anything about them.
  #
  # What the action was given is settled here too, for the same reason: which
  # atomics count as input is a question about what they are, and once a
  # sensitive one is `"**redacted**"` every one of them looks like a value. So
  # the changeset handed on holds all of it in `attributes`, whichever path the
  # write took — see `AshQuick.Audit.Row.given/2`.
  defp entry({changeset, record}, attributes, arguments) do
    given = Row.given(changeset, record)

    {redact(%{changeset | attributes: given}, attributes, arguments), record,
     Row.changes(changeset, record, attributes)}
  end

  # `atomics` is where an atomic update holds what it was given, so a secret
  # accepted there is as much in the changeset as one in `attributes`, and an
  # expression may carry one pinned inside it.
  defp redact(%Ash.Changeset{} = changeset, attributes, arguments) do
    %{
      changeset
      | attributes: redact(changeset.attributes, attributes),
        atomics: redact_atomics(changeset.atomics, attributes),
        arguments: redact(changeset.arguments, arguments),
        params: redact(changeset.params, param_keys(attributes ++ arguments))
    }
  end

  defp redact_atomics(atomics, names),
    do: Enum.reduce(names, atomics, &Keyword.replace(&2, &1, @redacted))

  # Params are the raw input, so a name arrives under whichever key kind the
  # caller used — a form submits strings, a code interface submits atoms — and
  # both are the same secret.
  defp param_keys(names), do: Enum.flat_map(names, &[&1, to_string(&1)])

  defp to_redact(%Ash.Changeset{resource: resource, action: action}) do
    recorded = Declaration.record_sensitive(resource)

    {sensitive_names(Ash.Resource.Info.attributes(resource)) -- recorded,
     sensitive_names(action.arguments) -- recorded}
  end

  defp sensitive_names(fields) do
    for %{sensitive?: true, name: name} <- fields, do: name
  end

  # `Map.replace/3` leaves a name the changeset never set alone, so the entry
  # says nothing about a field the action did not touch.
  defp redact(values, names), do: Enum.reduce(names, values, &Map.replace(&2, &1, @redacted))
end
