defmodule AshQuick.Audit.Change do
  @moduledoc """
  Hands a batch of writes to the resource's `AshQuick.Audit.Store`.

  Attached to every create, update and destroy of a resource carrying the
  AshQuick extension, since auditing is on unless a resource turns it off —
  see `AshQuick.Audit.Transformer` for the two it is never attached to. A
  resource that turns it off at resource level and wants only some of its
  actions audited attaches it to those by hand.

  Nothing is logged for a write with no actor: an audit entry names who made
  the change, and a system write has nobody to name. That is the only condition
  checked here — every other write in the batch is handed over.

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
  two ways to reach it: an attribute the read did not `select`, and a record
  that was never read at all, such as a hand-built `%Brand{id: id}`.

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

  @impl true
  def after_batch([{changeset, _record} | _] = changesets_and_results, _opts, %{actor: actor})
      when actor != nil do
    if excluded?(changeset) do
      :ok
    else
      Ash.Tracer.span :custom, "Audit Log", changeset.context[:private][:tracer] do
        log(changesets_and_results, actor)
      end
    end
  end

  def after_batch(_changesets_and_results, _opts, _context), do: :ok

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
  defp entry({changeset, record}, attributes, arguments) do
    {redact(changeset, attributes, arguments), record, Row.changes(changeset, attributes)}
  end

  defp redact(%Ash.Changeset{} = changeset, attributes, arguments) do
    %{
      changeset
      | attributes: redact(changeset.attributes, attributes),
        arguments: redact(changeset.arguments, arguments),
        params: redact(changeset.params, param_keys(attributes ++ arguments))
    }
  end

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
