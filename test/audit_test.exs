defmodule AshQuick.AuditTest do
  @moduledoc """
  What the audit store is handed.

  `AshQuick.Audit.Row` copies `changeset.attributes` and `changeset.arguments`
  into the row — the diff *is* the entry — so redaction cannot be left to the
  host: the first resource with a password argument would write plaintext into
  a table that is never rotated and is read by everyone holding audit access,
  and nothing would raise. `AshQuick.Test.Credential` is that resource.
  Everything around it is real: the write goes through `AshQuick.Audit.Change`
  into the configured store, and the assertions read back the persisted row
  that a host's `/audit_logs` renders.

  Redaction also covers `changeset.params`, the raw input behind those two.
  Nothing reads the params today — the row is built from the cast values — so
  that half is not asserted here; it is what keeps the batch safe for anything
  else handed it.

  What a store *refusing* the batch does to the write is not here: the contract
  is that the record goes back with the entry, and only a data layer with
  transactions can show that. The ETS fixtures have none, so that assertion
  lives in a host suite.
  """
  use ExUnit.Case, async: true

  require Ash.Query

  alias AshQuick.Test.Actor
  alias AshQuick.Test.AuditLog
  alias AshQuick.Test.Credential

  setup do
    actor =
      Actor
      |> Ash.Changeset.for_create(:create, %{name: "Auditor"})
      |> Ash.create!()

    %{actor: actor}
  end

  # The row's `attributes` and `arguments` are plain maps, so the ETS store
  # keeps the atom keys `AshQuick.Audit.Row` built them with. A host on a JSONB
  # column reads the same maps back with string keys — what is redacted is the
  # same either way, which is what these assert.
  defp entries(record) do
    AuditLog
    |> Ash.Query.filter(resource_id == ^record.id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!()
  end

  test "a sensitive attribute is redacted, and the one the resource records is not",
       %{actor: actor} do
    record =
      Credential
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Gateway",
          api_key: "sk-live-do-not-log",
          masked_card_number: "**** 4242"
        },
        actor: actor
      )
      |> Ash.create!()

    assert [entry] = entries(record)

    assert entry.attributes[:api_key] == "**redacted**"
    assert entry.attributes[:masked_card_number] == "**** 4242"
    # Without this, the assertion above would pass just as well against a change
    # that blanked the whole payload.
    assert entry.attributes[:name] == "Gateway"

    # The value the record itself still holds, and that the row must not repeat
    # anywhere — including a field this test does not name.
    assert record.api_key == "sk-live-do-not-log"
    refute inspect(entry) =~ "sk-live-do-not-log"
  end

  test "a sensitive argument never reaches the store", %{actor: actor} do
    record =
      Credential
      |> Ash.Changeset.for_create(:create, %{name: "Gateway"}, actor: actor)
      |> Ash.create!()

    updated =
      record
      |> Ash.Changeset.for_update(:rotate, %{password: "hunter2", reason: "quarterly"},
        actor: actor
      )
      |> Ash.update!()

    assert updated.api_key == "hunter2"

    assert [_created, entry] = entries(record)

    assert entry.arguments[:password] == "**redacted**"
    assert entry.arguments[:reason] == "quarterly"
    # The argument was written through to a sensitive attribute, which is the
    # other half of the same leak.
    assert entry.attributes[:api_key] == "**redacted**"
    refute inspect(entry) =~ "hunter2"
  end

  # `Credential` stamps no bookkeeping at all, which is the point: on a resource
  # that relates an actor, `relate_actor` refuses a non-record long before the
  # entry is built. A resource that stamps nothing is where the audit row is the
  # only thing asking who acted.
  test "an actor that is a bare id names them; one that is neither fails the write",
       %{actor: actor} do
    record =
      Credential
      |> Ash.Changeset.for_create(:create, %{name: "Gateway"}, actor: actor.id)
      |> Ash.create!()

    # Ash takes any term as an actor, and a caller that already holds the id
    # passes that rather than reading the record back — the entry names them
    # either way.
    assert [entry] = entries(record)
    assert entry.actor_id == actor.id
    assert entry.real_actor_id == actor.id

    # An actor with no id has nobody for the entry to point at, and a row saying
    # nobody did it is the one somebody will come looking for.
    error =
      assert_raise Ash.Error.Unknown, fn ->
        Credential
        |> Ash.Changeset.for_create(:create, %{name: "Gateway"}, actor: %{role: :importer})
        |> Ash.create!()
      end

    message = Exception.message(error)

    assert message =~ "the audit entry cannot name the actor it was written by"
    assert message =~ inspect(Credential)
    assert message =~ "role: :importer"
  end
end
