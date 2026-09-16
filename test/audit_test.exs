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

  `changes` is the other half of the entry and the newer one: `attributes` says
  what the action was given, `changes` says what the values were before it. It
  is optional on the store — `AshQuick.Test.LegacyCredential` records into one
  that predates the column and must still get its rows — so the assertions cover
  both shapes.

  What a store *refusing* the batch does to the write is not here: the contract
  is that the record goes back with the entry, and only a data layer with
  transactions can show that. The ETS fixtures have none, so that assertion
  lives in a host suite.
  """
  use ExUnit.Case, async: true

  require Ash.Query

  alias AshQuick.Audit.Row
  alias AshQuick.Test.Actor
  alias AshQuick.Test.AuditLog
  alias AshQuick.Test.Credential
  alias AshQuick.Test.LegacyAuditStore
  alias AshQuick.Test.LegacyCredential

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

  describe "changes" do
    setup %{actor: actor} do
      record =
        Credential
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Gateway", api_key: "sk-1", masked_card_number: "**** 4242"},
          actor: actor
        )
        |> Ash.create!()

      %{record: record}
    end

    test "a create records every attribute it set, and no `from`",
         %{record: record} do
      assert [entry] = entries(record)

      assert entry.changes[:name] == %{to: "Gateway"}
      assert entry.changes[:masked_card_number] == %{to: "**** 4242"}
      # The default the changeset filled is an attribute the action set like any
      # other, and is what the row's `resource_id` points at.
      assert entry.changes[:id] == %{to: record.id}

      refute Enum.any?(entry.changes, fn {_name, change} -> Map.has_key?(change, :from) end)
    end

    test "an update records `from` and `to`, and says nothing about a key that did not change",
         %{actor: actor, record: record} do
      record
      |> Ash.Changeset.for_update(
        :update,
        # The second is the value it already holds, which is what an edit form
        # submits for every field the person did not touch.
        %{name: "Gateway 2", masked_card_number: "**** 4242"},
        actor: actor
      )
      |> Ash.update!()

      assert [_created, entry] = entries(record)

      assert entry.changes == %{name: %{from: "Gateway", to: "Gateway 2"}}
    end

    test "a destroy records the record as it stood", %{actor: actor, record: record} do
      Ash.destroy!(record, actor: actor)

      assert [_created, entry] = entries(record)

      # Every attribute rather than the ones some action named — a destroy sets
      # nothing, so there is no changeset to read the keys off.
      assert entry.changes == %{
               id: %{from: record.id},
               name: %{from: "Gateway"},
               api_key: %{from: "**redacted**"},
               masked_card_number: %{from: "**** 4242"}
             }
    end

    test "an attribute the read did not select is unknown rather than nil",
         %{actor: actor, record: record} do
      [selected] =
        Credential
        |> Ash.Query.filter(id == ^record.id)
        |> Ash.Query.select([:id, :masked_card_number])
        |> Ash.read!(actor: actor)

      assert %Ash.NotLoaded{} = selected.name

      selected
      |> Ash.Changeset.for_update(:update, %{name: "Gateway 2"}, actor: actor)
      |> Ash.update!()

      assert [_created, entry] = entries(record)

      # `from: nil` would say the name had been blank, which is a different
      # claim from not knowing what it was.
      assert entry.changes == %{name: %{from_unknown: true, to: "Gateway 2"}}
    end

    test "a record that was never read is unknown in every key", %{actor: actor, record: record} do
      # In Ash 3 a hand-built struct holds defaults rather than `Ash.NotLoaded`,
      # so a `nil` here is evidence of nothing and only `__meta__` says so.
      built = %Credential{id: record.id}

      assert built.name == nil
      assert built.__meta__.state == :built

      changeset =
        Ash.Changeset.for_update(
          built,
          :update,
          %{name: "Gateway 2", masked_card_number: "**** 1111"},
          actor: actor
        )

      assert Row.changes(changeset, []) == %{
               name: %{from_unknown: true, to: "Gateway 2"},
               masked_card_number: %{from_unknown: true, to: "**** 1111"}
             }
    end

    test "a sensitive attribute is redacted on both sides, and left out when it did not change",
         %{actor: actor, record: record} do
      rotated =
        record
        |> Ash.Changeset.for_update(:rotate, %{password: "sk-2"}, actor: actor)
        |> Ash.update!()

      assert [_created, entry] = entries(record)

      # The comparison ran on the real values — they differ — and only what is
      # recorded is redacted.
      assert entry.changes == %{api_key: %{from: "**redacted**", to: "**redacted**"}}
      refute inspect(entry) =~ "sk-1"
      refute inspect(entry) =~ "sk-2"

      # Rotated to what it already held: redacting before the comparison would
      # have reported a change between two identical redactions.
      rotated
      |> Ash.Changeset.for_update(:rotate, %{password: "sk-2"}, actor: actor)
      |> Ash.update!()

      assert [_created, _rotated, unchanged] = entries(record)

      # Still a row, as an empty changeset is: an action that wrote nothing is
      # not an action that did nothing.
      assert unchanged.changes == %{}
    end

    test "a store that predates the column is written without it", %{actor: actor} do
      record =
        LegacyCredential
        |> Ash.Changeset.for_create(:create, %{name: "Gateway"}, actor: actor)
        |> Ash.create!()

      assert [entry] =
               LegacyAuditStore
               |> Ash.Query.filter(resource_id == ^record.id)
               |> Ash.read!()

      # `Ash.bulk_create` refuses an input the action does not have, so the key
      # has to be absent from the row rather than nil — the row lands, and says
      # what it always said.
      refute Map.has_key?(entry, :changes)
      assert entry.attributes[:name] == "Gateway"
    end
  end
end
