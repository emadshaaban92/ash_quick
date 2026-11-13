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

  require Ash.Expr
  require Ash.Query

  alias AshQuick.Audit.Expression
  alias AshQuick.Audit.Row
  alias AshQuick.Test.Actor
  alias AshQuick.Test.AuditLog
  alias AshQuick.Test.Credential
  alias AshQuick.Test.Dossier
  alias AshQuick.Test.DossierFolder
  alias AshQuick.Test.JsonAuditStore
  alias AshQuick.Test.LegacyAuditStore
  alias AshQuick.Test.LegacyCredential
  alias AshQuick.Test.NumberedCredential
  alias AshQuick.Test.RefusedDossier
  alias AshQuick.Test.Report
  alias AshQuick.Test.Scopes.FullScope
  alias AshQuick.Test.StampedTally
  alias AshQuick.Test.Tally
  alias AshQuick.Test.TextKeyAuditStore
  alias AshQuick.Test.VersionedTally

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

  describe "a write with no actor" do
    # A background job, a scheduled task, an integration: nobody is behind the
    # write, and the row says so rather than leaving no trace it happened.
    test "is recorded, naming nobody" do
      record =
        Credential
        |> Ash.Changeset.for_create(:create, %{name: "Gateway", api_key: "sk-job"})
        |> Ash.create!()

      updated =
        record
        |> Ash.Changeset.for_update(:rotate, %{password: "sk-2", reason: "nightly"})
        |> Ash.update!()

      assert [created, rotated] = entries(record)

      assert created.actor_id == nil
      assert created.real_actor_id == nil
      assert created.action_name == :create
      assert created.attributes[:name] == "Gateway"
      assert created.changes[:name] == %{to: "Gateway"}

      assert rotated.actor_id == nil
      assert rotated.real_actor_id == nil
      assert rotated.action_name == :rotate
      assert rotated.arguments[:reason] == "nightly"
      assert rotated.arguments[:password] == "**redacted**"
      assert rotated.changes[:api_key] == %{from: "**redacted**", to: "**redacted**"}
      assert updated.api_key == "sk-2"
    end

    test "keeps what its context says made it" do
      record =
        Credential
        |> Ash.Changeset.for_create(:create, %{name: "Gateway"},
          context: %{action_source: "nightly_sync", queue: :scheduled, run: %{id: 42}}
        )
        |> Ash.create!()

      assert [entry] = entries(record)

      assert entry.actor_id == nil
      assert entry.context[:action_source] == "nightly_sync"
      # `action_source` is the key to use, not the only one kept: `Credential`
      # lists `:queue` in `record_context`.
      assert entry.context[:queue] == :scheduled
      # Flat values only — a nested one is not kept.
      refute Map.has_key?(entry.context, :run)
    end

    test "in bulk records one row per record" do
      %Ash.BulkResult{status: :success, records: records} =
        Ash.bulk_create(
          [%{name: "One"}, %{name: "Two"}, %{name: "Three"}],
          Credential,
          :create,
          return_records?: true,
          return_errors?: true
        )

      assert length(records) == 3

      for record <- records do
        assert [entry] = entries(record)
        assert entry.actor_id == nil
        assert entry.attributes[:name] == record.name
      end
    end
  end

  # `exclude_actions` is how a host keeps a write out of the log, and passing no
  # actor is not — so it has to hold either way.
  test "an excluded action records nothing, with or without an actor", %{actor: actor} do
    record =
      Credential
      |> Ash.Changeset.for_create(:create, %{name: "Gateway"}, actor: actor)
      |> Ash.create!()

    record |> Ash.Changeset.for_update(:touch, %{}, actor: actor) |> Ash.update!()
    record |> Ash.Changeset.for_update(:touch, %{}) |> Ash.update!()

    assert [entry] = entries(record)
    assert entry.action_name == :create
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

      assert Row.changes(changeset, built, [], []) == %{
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

    # The installer's store keeps `resource_id` as text, so a host keyed by
    # integers gets rows as one keyed by UUIDs does.
    test "an integer key is written as text", %{actor: actor} do
      NumberedCredential
      |> Ash.Changeset.for_create(:create, %{id: 42, name: "Gateway"}, actor: actor)
      |> Ash.create!()

      assert [entry] =
               TextKeyAuditStore
               |> Ash.Query.filter(resource_id == "42")
               |> Ash.read!()

      assert entry.resource_name == :numbered_credential
    end
  end

  # An unversioned resource keeps Ash's default, `require_atomic? true`, and an
  # atomic update builds no in-memory changeset: what it was given is in
  # `changeset.atomics`, and what an expression came to is only in the record
  # the write returned.
  describe "an atomic write" do
    setup %{actor: actor} do
      record =
        Tally
        |> Ash.Changeset.for_create(:create, %{name: "Gate", pin: "pin-1111-zq"}, actor: actor)
        |> Ash.create!()

      %{record: record}
    end

    test "Tally's actions really are atomic" do
      # Without this, everything below would pass just as well on the
      # in-memory path the audit change has always handled.
      for name <- [
            :rename,
            :bump,
            :bump_by,
            :bump_secretly,
            :measure,
            :exclaim,
            :double_up,
            :sign,
            :remove
          ] do
        assert Ash.Resource.Info.action(Tally, name).require_atomic?
      end
    end

    test "an update records what it was given and what changed, with secrets redacted",
         %{actor: actor, record: record} do
      record
      |> Ash.Changeset.for_update(:rename, %{name: "Gate 2", pin: "pin-2222-zq"}, actor: actor)
      |> Ash.update!()

      assert [_created, entry] = entries(record)

      assert entry.action_name == :rename
      assert entry.actor_id == actor.id
      assert entry.attributes == %{name: "Gate 2", pin: "**redacted**"}

      assert entry.changes == %{
               name: %{from: "Gate", to: "Gate 2"},
               pin: %{from: "**redacted**", to: "**redacted**"}
             }

      # Not digits alone: the entry holds random UUIDs, which can hold any
      # four of them.
      refute inspect(entry) =~ "pin-1111-zq"
      refute inspect(entry) =~ "pin-2222-zq"
    end

    test "an expression is recorded as what it came to, and not as input",
         %{actor: actor, record: record} do
      bumped =
        record
        |> Ash.Changeset.for_update(:bump, %{}, actor: actor)
        |> Ash.update!()

      assert bumped.count == 1

      assert [_created, entry] = entries(record)

      # `count + 1` is something a change asked of the data layer rather than
      # something the action was given, and `changes` keeps it beside what it
      # came to.
      assert entry.attributes == %{}
      assert entry.changes == %{count: %{from: 0, to: 1, expr: "count + 1"}}
    end

    test "an expression holds the value of an argument it was given",
         %{actor: actor, record: record} do
      record
      |> Ash.Changeset.for_update(:bump_by, %{by: 5}, actor: actor)
      |> Ash.update!()

      assert [_created, entry] = entries(record)

      assert entry.changes == %{count: %{from: 0, to: 5, expr: "count + 5"}}
    end

    test "an expression reads as written, without the checks Ash wraps it in",
         %{actor: actor, record: record} do
      # A required attribute set by something that can come to nil, which Ash
      # wraps in a required check …
      record
      |> Ash.Changeset.for_update(:measure, %{}, actor: actor)
      |> Ash.update!()

      # … and a string, which `Ash.Type.String` trims and turns nil when empty.
      record
      |> Ash.Changeset.for_update(:exclaim, %{}, actor: actor)
      |> Ash.update!()

      assert [_created, measured, exclaimed] = entries(record)

      assert measured.changes == %{count: %{from: 0, to: 4, expr: "string_length(name)"}}
      assert exclaimed.changes == %{name: %{from: "Gate", to: "Gate!", expr: ~s(name <> "!")}}
    end

    test "a sensitive argument in an expression never appears in the entry",
         %{actor: actor, record: record} do
      record
      |> Ash.Changeset.for_update(:bump_secretly, %{bonus: 987_654_321}, actor: actor)
      |> Ash.update!()

      assert [_created, entry] = entries(record)

      # `count + (1 + 987654321)` is folded into `count + 987654322`: a literal
      # derived from the secret, which no comparison with it would find. `to`
      # is the count, not a secret.
      assert entry.changes == %{count: %{from: 0, to: 987_654_322, expr: "count + **redacted**"}}
      assert entry.arguments == %{bonus: "**redacted**"}
      # Nine digits, not four: the entry holds random UUIDs, which can hold any
      # four of them.
      refute inspect(entry) =~ "987654321"
    end

    test "a secret another attribute's expression reads is redacted there too",
         %{actor: actor, record: record} do
      record
      |> Ash.Changeset.for_update(:sign, %{pin: "9876"}, actor: actor)
      |> Ash.update!()

      assert [_created, entry] = entries(record)

      # `^atomic_ref(:pin)` is the new pin itself. `<>` groups to the right, as
      # in Elixir.
      assert entry.changes == %{
               name: %{from: "Gate", to: "Gate/9876", expr: ~s[name <> ("/" <> **redacted**)]},
               pin: %{from: "**redacted**", to: "**redacted**"}
             }

      refute inspect(entry.changes.name.expr) =~ "9876"
    end

    test "a sensitive expression is redacted, and not recorded as input",
         %{actor: actor, record: record} do
      scrambled =
        record
        |> Ash.Changeset.for_update(:scramble, %{}, actor: actor)
        |> Ash.update!()

      assert scrambled.pin == "Gate-0000"

      assert [_created, entry] = entries(record)

      # Redacted in `atomics` like any other secret there — and the action was
      # given nothing, so `attributes` still says so.
      assert entry.attributes == %{}

      assert entry.changes == %{
               pin: %{from: "**redacted**", to: "**redacted**", expr: "**redacted**"}
             }

      refute inspect(entry) =~ "Gate-0000"
    end

    test "an input the type cast to an expression is recorded as what it came to",
         %{record: record} do
      # A type can cast an input atomically into an expression, which the
      # in-memory path would have recorded as a value. ETS keeps a string a
      # string, so the expression is put in place by hand.
      changeset =
        record
        |> Ash.Changeset.for_update(:rename, %{name: "Gate 2"})
        |> Ash.Changeset.atomic_update(:name, Ash.Expr.expr(name <> " 2"))

      assert Row.given(changeset, %{record | name: "Gate 2"}) == %{name: "Gate 2"}

      # Nor is its expression one to keep: what the caller passed is the value.
      assert Row.changes(changeset, %{record | name: "Gate 2"}, [], []) == %{
               name: %{from: "Gate", to: "Gate 2"}
             }

      # One a change asked for is not input on either path.
      bumped = Ash.Changeset.for_update(record, :bump, %{})

      assert Row.given(bumped, %{record | count: 1}) == %{}
    end

    test "an expression renders on one line, whole, with values as Elixir writes them" do
      attributes = Ash.Resource.Info.attributes(Tally)
      count = Ash.Resource.Info.attribute(Tally, :count)
      long = String.duplicate("x", 120)

      expression =
        Ash.Expr.expr(
          if count > ^Decimal.new("1.50") and ^~U[2026-11-03 10:00:00Z] > now() do
            count + 1
          else
            string_length(^long)
          end
        )

      # Ash renders an `if` over several lines; nothing is cut short.
      assert Expression.render(expression, count, attributes, %{given: [], held: []}) ==
               ~s{if (count > Decimal.new("1.50")) and (~U[2026-11-03 10:00:00Z] > now()) } <>
                 ~s{do count + 1 else string_length("#{long}") end}
    end

    test "a short secret is not looked for inside other text", %{actor: actor} do
      record =
        Tally
        |> Ash.Changeset.for_create(:create, %{name: "Gate", pin: "nt"}, actor: actor)
        |> Ash.create!()

      record
      |> Ash.Changeset.for_update(:bump, %{}, actor: actor)
      |> Ash.update!()

      assert [_created, entry] = entries(record)

      # "nt" is inside `count`, by chance rather than because the pin is.
      assert entry.changes == %{count: %{from: 0, to: 1, expr: "count + 1"}}
    end

    test "an expression Ash has not resolved is walked all the same" do
      attributes = Ash.Resource.Info.attributes(Tally)
      count = Ash.Resource.Info.attribute(Tally, :count)
      bonus = 4242

      # Calls by name, as written: their arguments are a list.
      expression = Ash.Expr.expr(count + (1 + ^bonus))

      assert Expression.render(expression, count, attributes, %{given: [bonus], held: []}) ==
               "count + (**redacted** + **redacted**)"
    end

    test "an expression keeps its grouping", %{actor: actor, record: record} do
      record
      |> Ash.Changeset.for_update(:double_up, %{}, actor: actor)
      |> Ash.update!()

      assert [_created, entry] = entries(record)

      # Ash prints an operator's operands without parentheses, which here would
      # read `count + 1 * 2`: a different formula from the one that ran.
      assert entry.changes == %{count: %{from: 0, to: 2, expr: "(count + 1) * 2"}}

      attributes = Ash.Resource.Info.attributes(Tally)
      count = Ash.Resource.Info.attribute(Tally, :count)
      none = %{given: [], held: []}

      {:ok, regrouped} =
        Ash.Filter.hydrate_refs(Ash.Expr.expr(count - (count - 1)), %{
          resource: Tally,
          public?: false
        })

      assert Expression.render(regrouped, count, attributes, none) == "count - (count - 1)"
    end

    test "a secret where the walk does not reach takes the whole expression with it" do
      attributes = Ash.Resource.Info.attributes(Tally)
      count = Ash.Resource.Info.attribute(Tally, :count)

      # An `exists` is left to whoever walks an expression to look inside.
      expression = Ash.Expr.expr(count + exists(items, name == ^"9876"))

      assert Expression.render(expression, count, attributes, %{given: [], held: ["9876"]}) ==
               "**redacted**"
    end

    test "a versioned resource's counter keeps no expression, and is recorded as set",
         %{actor: actor} do
      record =
        VersionedTally
        |> Ash.Changeset.for_create(:create, %{name: "Gate", pin: "1111"}, actor: actor)
        |> Ash.create!()

      for action <- [:bump, :scramble] do
        assert Ash.Resource.Info.action(VersionedTally, action).require_atomic?
      end

      bumped =
        record
        |> Ash.Changeset.for_update(:bump, %{}, actor: actor)
        |> Ash.update!()

      scrambled =
        bumped
        |> Ash.Changeset.for_update(:scramble, %{}, actor: actor)
        |> Ash.update!()

      assert [_created, bump, scramble] = entries(record)

      # The lock's `if <changed> do version + 1 else version end` is bookkeeping
      # rather than something a change asked for, and the in-memory path
      # records the counter as a value.
      assert bump.changes == %{
               count: %{from: 0, to: 1, expr: "count + 1"},
               version: %{from: record.version, to: bumped.version}
             }

      assert bump.attributes == %{version: bumped.version}

      # That expression repeats `name <> "-0000"`, which says how the secret
      # was built.
      assert scramble.changes == %{
               pin: %{from: "**redacted**", to: "**redacted**", expr: "**redacted**"},
               version: %{from: bumped.version, to: scrambled.version}
             }

      refute inspect(scramble) =~ "-0000"
    end

    test "an update default keeps no expression", %{actor: actor} do
      record =
        StampedTally
        |> Ash.Changeset.for_create(:create, %{name: "Gate"}, actor: actor)
        |> Ash.create!()

      assert Ash.Resource.Info.action(StampedTally, :bump).require_atomic?

      bumped =
        record
        |> Ash.Changeset.for_update(:bump, %{}, actor: actor)
        |> Ash.update!()

      assert [_created, entry] = entries(record)

      # `touched_at` arrived as `if <changed> do now() else touched_at end`.
      assert entry.changes.count == %{from: 0, to: 1, expr: "count + 1"}
      assert entry.changes.touched_at == %{from: record.touched_at, to: bumped.touched_at}
    end

    test "a new value the write did not return is unknown rather than recorded",
         %{record: record} do
      changeset = Ash.Changeset.for_update(record, :bump, %{})

      # A `select` that leaves the attribute out of what an atomic write returns.
      returned = %{record | count: %Ash.NotLoaded{field: :count, type: :attribute}}

      assert Row.changes(changeset, returned, [], []) == %{
               count: %{from: 0, to_unknown: true, expr: "count + 1"}
             }
    end

    test "an expression on an action that is not atomic is recorded the same way",
         %{actor: actor, record: record} do
      refute Ash.Resource.Info.action(Tally, :bump_in_memory).require_atomic?

      bumped =
        record
        |> Ash.Changeset.for_update(:bump_in_memory, %{}, actor: actor)
        |> Ash.update!()

      assert bumped.count == 1

      assert [_created, entry] = entries(record)

      # `changeset.attributes` is empty here too: an `atomic_update` sends its
      # attribute through `changeset.atomics` on either path.
      assert entry.changes == %{count: %{from: 0, to: 1, expr: "count + 1"}}
    end

    test "a bulk update by query has no record to read `from` off",
         %{actor: actor, record: record} do
      assert %Ash.BulkResult{status: :success} =
               Tally
               |> Ash.Query.filter(id == ^record.id)
               |> Ash.bulk_update!(:rename, %{name: "Gate 3"},
                 strategy: :atomic,
                 actor: actor,
                 return_errors?: true
               )

      assert [_created, entry] = entries(record)

      # The rows were never read into memory, so the previous value is unknown
      # rather than `nil` — and `to` still is what the row now holds.
      assert entry.changes == %{name: %{from_unknown: true, to: "Gate 3"}}
    end

    test "a bulk update by query keeps its expression beside an unknown `from`",
         %{actor: actor, record: record} do
      for {action, input} <- [bump_by: %{by: 5}, bump_secretly: %{bonus: 987_654_321}] do
        assert %Ash.BulkResult{status: :success} =
                 Tally
                 |> Ash.Query.filter(id == ^record.id)
                 |> Ash.bulk_update!(action, input,
                   strategy: :atomic,
                   actor: actor,
                   return_errors?: true
                 )
      end

      assert [_created, by, secretly] = entries(record)

      # Which is when `expr` says most: `from` is unknown, and `count + 5` is
      # still what happened.
      assert by.changes == %{count: %{from_unknown: true, to: 5, expr: "count + 5"}}

      assert secretly.changes == %{
               count: %{from_unknown: true, to: 987_654_327, expr: "count + **redacted**"}
             }

      # Nine digits, as above.
      refute inspect(secretly) =~ "987654321"
    end

    test "a bulk destroy by query records the rows it deleted as they stood",
         %{actor: actor, record: record} do
      assert %Ash.BulkResult{status: :success} =
               Tally
               |> Ash.Query.filter(id == ^record.id)
               |> Ash.bulk_destroy!(:remove, %{},
                 strategy: :atomic,
                 actor: actor,
                 return_errors?: true
               )

      assert [_created, entry] = entries(record)

      # Nothing was read into memory, but the rows the data layer deleted come
      # back as they stood, so every `from` is known.
      assert entry.changes == %{
               id: %{from: record.id},
               name: %{from: "Gate"},
               count: %{from: 0},
               pin: %{from: "**redacted**"}
             }
    end

    test "a destroy records the record as it stood", %{actor: actor, record: record} do
      Ash.destroy!(record, action: :remove, actor: actor)

      assert [_created, entry] = entries(record)

      assert entry.action_name == :remove

      assert entry.changes == %{
               id: %{from: record.id},
               name: %{from: "Gate"},
               count: %{from: 0},
               pin: %{from: "**redacted**"}
             }
    end
  end

  describe "an audited read" do
    # `Dossier` lists `:open` and `:browse` in `read_actions`; its primary
    # `:read` stands for every list and search, which records nothing. Its read
    # policy shows an actor only their own dossiers.
    setup %{actor: actor} do
      folder =
        DossierFolder |> Ash.Changeset.for_create(:create, %{name: "Case"}) |> Ash.create!()

      dossiers =
        for title <- ["One", "Two", "Three"] do
          Dossier
          |> Ash.Changeset.for_create(:create, %{
            title: title,
            owner_id: actor.id,
            folder_id: folder.id
          })
          |> Ash.create!()
        end

      %{dossiers: dossiers, folder: folder}
    end

    # Every row a dossier read wrote, oldest first. A dossier's create is
    # audited too, so the reads are picked out by their type.
    defp reads(dossiers) do
      ids = Enum.map(List.wrap(dossiers), & &1.id)

      AuditLog
      |> Ash.Query.filter(resource_id in ^ids and action_type == :read)
      |> Ash.Query.sort(id: :asc)
      |> Ash.read!()
    end

    test "a get? read records the record it returned, with who, from where and why",
         %{actor: actor, dossiers: [dossier | _]} do
      real = Actor |> Ash.Changeset.for_create(:create, %{name: "Support"}) |> Ash.create!()
      scope = %FullScope{user: actor, behind: real, pretending?: true, from: "10.0.0.9"}

      opened =
        Dossier
        |> Ash.Query.filter(id == ^dossier.id)
        |> Ash.Query.for_read(
          :open,
          %{code: "pin-zq-code", badge: "badge-7", purpose: "review"},
          scope: scope,
          context: %{action_source: "dossier_page", run: %{id: 42}}
        )
        |> Ash.read_one!()

      assert opened.id == dossier.id

      assert [entry] = reads(dossier)
      assert entry.resource_name == :dossier
      assert entry.action_type == :read
      assert entry.action_name == :open
      assert entry.actor_id == actor.id
      assert entry.real_actor_id == real.id
      assert entry.ip == "10.0.0.9"
      assert entry.attributes == %{}
      assert entry.changes == %{}
      assert entry.arguments[:purpose] == "review"
      assert entry.arguments[:code] == "**redacted**"
      # Named in `record_sensitive`, so kept, as on a write.
      assert entry.arguments[:badge] == "badge-7"
      assert entry.context[:action_source] == "dossier_page"
      refute Map.has_key?(entry.context, :run)
      refute inspect(entry) =~ "pin-zq-code"
    end

    test "Ash.get and a code interface record the same way",
         %{actor: actor, dossiers: [dossier | _]} do
      Ash.get!(Dossier, dossier.id, action: :open, actor: actor)
      Dossier.open!(dossier.id, actor: actor)

      assert [first, second] = reads(dossier)
      assert first.action_name == :open
      assert second.action_name == :open
      assert first.real_actor_id == actor.id
    end

    test "a read returning several records records each of them",
         %{actor: actor, dossiers: dossiers} do
      assert length(Ash.read!(Dossier, action: :browse, actor: actor)) == 3

      entries = reads(dossiers)
      assert length(entries) == 3

      assert entries |> Enum.map(& &1.resource_id) |> Enum.sort() ==
               dossiers |> Enum.map(& &1.id) |> Enum.sort()

      assert Enum.all?(entries, &(&1.action_name == :browse))
    end

    test "a page records the records on it, and no others", %{actor: actor, dossiers: dossiers} do
      sorted = Ash.Query.sort(Dossier, title: :asc)

      # One, Three / Three, Two.
      for pagination <- [[limit: 2], [limit: 2, offset: 1]] do
        page = Ash.read!(sorted, action: :browse, actor: actor, page: pagination)
        assert length(page.results) == 2
      end

      # Keyset pagination reads one row past the page to know whether there is
      # another; that one was not returned and is not recorded.
      page = Ash.read!(sorted, action: :browse, actor: actor, page: [limit: 1])
      assert [%{title: "One"}] = page.results
      assert page.more?

      entries = reads(dossiers)

      assert Map.new(dossiers, fn dossier ->
               {dossier.title, Enum.count(entries, &(&1.resource_id == dossier.id))}
             end) == %{"One" => 2, "Three" => 2, "Two" => 1}
    end

    test "a stream records every record it yields", %{actor: actor, dossiers: dossiers} do
      # `Ash.stream!/2` takes the action off the query.
      streamed =
        Dossier
        |> Ash.Query.for_read(:browse, %{}, actor: actor)
        |> Ash.stream!(actor: actor, batch_size: 2)
        |> Enum.to_list()

      assert length(streamed) == 3

      entries = reads(dossiers)

      assert entries |> Enum.map(& &1.resource_id) |> Enum.sort() ==
               dossiers |> Enum.map(& &1.id) |> Enum.sort()
    end

    test "loading a relationship through a listed action records what it loaded",
         %{actor: actor, dossiers: dossiers, folder: folder} do
      loaded = Ash.load!(folder, :dossiers, actor: actor)
      assert length(loaded.dossiers) == 3

      entries = reads(dossiers)
      assert length(entries) == 3
      assert Enum.all?(entries, &(&1.action_name == :browse))
      # The folder's own read is not listed.
      assert reads(folder) == []
    end

    test "loading onto records already in hand records nothing",
         %{actor: actor, dossiers: dossiers} do
      loaded = Ash.load!(dossiers, :heading, action: :browse, actor: actor)
      assert Enum.map(loaded, & &1.heading) == ["One!", "Two!", "Three!"]

      # A field the records were read without is read again for them, through
      # the action, and that is still not a read of anything new.
      bare =
        Dossier
        |> Ash.Query.select([:id, :owner_id])
        |> Ash.read!(actor: actor)

      reloaded = Ash.load!(bare, [:title, :heading], action: :browse, actor: actor)
      assert reloaded |> Enum.map(& &1.heading) |> Enum.sort() == ["One!", "Three!", "Two!"]

      assert reads(dossiers) == []
    end

    test "a read that returns nothing records nothing",
         %{actor: actor, dossiers: [dossier | _] = dossiers} do
      stranger = Actor |> Ash.Changeset.for_create(:create, %{name: "Stranger"}) |> Ash.create!()

      # Not found.
      assert {:error, _} = Ash.get(Dossier, Ash.UUID.generate(), action: :open, actor: actor)
      # There, but the read policy filters it out for this actor.
      assert {:error, _} = Ash.get(Dossier, dossier.id, action: :open, actor: stranger)
      assert [] = Ash.read!(Dossier, action: :browse, actor: stranger)

      assert reads(dossiers) == []
    end

    test "a record another hook drops after the read is not recorded",
         %{actor: actor, dossiers: dossiers, folder: folder} do
      hidden =
        Dossier
        |> Ash.Changeset.for_create(:create, %{
          title: "Hidden",
          owner_id: actor.id,
          folder_id: folder.id,
          hidden?: true
        })
        |> Ash.create!()

      assert length(Ash.read!(Dossier, action: :browse, actor: actor)) == 3
      assert {:error, _} = Ash.get(Dossier, hidden.id, action: :open, actor: actor)
      assert length(Ash.load!(folder, :dossiers, actor: actor).dossiers) == 3

      streamed =
        Dossier
        |> Ash.Query.for_read(:browse, %{}, actor: actor)
        |> Ash.stream!(actor: actor, batch_size: 2)
        |> Enum.to_list()

      assert length(streamed) == 3

      assert reads(hidden) == []
      assert length(reads(dossiers)) == 9
    end

    test "a read through an action that is not listed records nothing",
         %{actor: actor, dossiers: dossiers} do
      assert length(Ash.read!(Dossier, actor: actor)) == 3
      assert Ash.get!(Dossier, hd(dossiers).id, actor: actor)

      assert reads(dossiers) == []
    end

    # Ash builds the read's query for a check, and with it the preparation, so
    # what is asserted is that nothing at all is written under the checks'
    # context — not only nothing naming these dossiers.
    test "a permission check on a listed action records nothing",
         %{actor: actor, dossiers: [dossier | _] = dossiers} do
      probe = "can-#{System.unique_integer([:positive])}"
      opts = [context: %{probe: probe}]

      assert Ash.can?({Dossier, :browse}, actor, opts)
      assert Ash.can?({Dossier, :open, %{purpose: "check"}}, actor, opts)
      assert Ash.can?({dossier, :open, %{code: "pin-zq-code"}}, actor, opts)
      assert Ash.can?({dossier, :browse}, actor, opts)
      assert AshQuick.can?({Dossier, :browse}, actor, :ash_quick_list, opts)
      assert AshQuick.can?({dossier, :browse}, actor, :ash_quick_details, opts)

      assert reads(dossiers) == []
      refute Enum.any?(Ash.read!(AuditLog), &(&1.context[:probe] == probe))
    end

    test "a read whose rows the store refuses fails, and returns nothing" do
      record =
        RefusedDossier |> Ash.Changeset.for_create(:create, %{title: "Sealed"}) |> Ash.create!()

      error =
        assert_raise Ash.Error.Unknown, fn ->
          Ash.get!(RefusedDossier, record.id, action: :open)
        end

      assert Exception.message(error) =~ "the audit entry could not be written"
      assert Exception.message(error) =~ "The read it records returns nothing"

      # The same read through an unlisted action is not recorded, and so not
      # refused.
      assert Ash.get!(RefusedDossier, record.id).id == record.id
    end
  end

  # The row's `context` holds `action_source` and the keys the resource lists
  # in `record_context`, and nothing else: a context holds whatever any part of
  # the pipeline put there, and an unlisted key cannot reach the store.
  describe "the row's context" do
    setup %{actor: actor} do
      report =
        Report
        |> Ash.Changeset.for_create(:create, %{title: "Quarterly"}, actor: actor)
        |> Ash.create!()

      %{report: report}
    end

    defp report_entries(report) do
      JsonAuditStore
      |> Ash.Query.filter(resource_id == ^report.id)
      |> Ash.Query.sort(id: :asc)
      |> Ash.read!()
    end

    defp export(report, actor, args \\ %{}, opts \\ []) do
      report
      |> Ash.Changeset.for_update(:export, args, [actor: actor] ++ opts)
      |> Ash.update()
    end

    test "keeps nothing an action carried between its own hooks",
         %{actor: actor, report: report} do
      assert {:ok, exported} = export(report, actor)
      assert exported.__metadata__.ash_quick_download.data == "zq-report-body"

      assert [_created, entry] = report_entries(report)
      assert entry.action_name == :export
      refute Map.has_key?(entry.context, :copy)
      refute inspect(entry) =~ "zq-report-body"
    end

    test "keeps the write whose carried bytes are not valid UTF-8",
         %{actor: actor, report: report} do
      assert {:ok, exported} = export(report, actor, %{format: "bin"})
      refute String.valid?(exported.__metadata__.ash_quick_download.data)

      assert [_created, entry] = report_entries(report)
      assert entry.action_name == :export
      assert entry.arguments[:filename] == "report.bin"
      refute Map.has_key?(entry.context, :copy)
      refute inspect(entry) =~ "zq-report-body"
    end

    test "keeps `action_source` with nothing listed, on a write and on a read",
         %{actor: actor, report: report} do
      assert AshQuick.Audit.Declaration.record_context(Report) == []

      {:ok, _exported} = export(report, actor, %{}, context: %{action_source: :ash_quick_form})

      Report
      |> Ash.Query.filter(id == ^report.id)
      |> Ash.Query.for_read(:open, %{}, actor: actor, context: %{action_source: "report_page"})
      |> Ash.read_one!()

      assert [_created, written, read] = report_entries(report)
      assert written.context == %{action_source: :ash_quick_form}
      assert read.action_type == :read
      assert read.context == %{action_source: "report_page"}
    end

    test "keeps a listed key on a write and on a read, and drops it where unlisted",
         %{actor: actor, report: report} do
      context = %{action_source: "support", ticket: "T-1042"}

      credential =
        Credential
        |> Ash.Changeset.for_create(:create, %{name: "Gateway"}, actor: actor, context: context)
        |> Ash.create!()

      dossier =
        Dossier
        |> Ash.Changeset.for_create(:create, %{title: "One", owner_id: actor.id})
        |> Ash.create!()

      Dossier
      |> Ash.Query.filter(id == ^dossier.id)
      |> Ash.Query.for_read(:open, %{}, actor: actor, context: context)
      |> Ash.read_one!()

      {:ok, _exported} = export(report, actor, %{}, context: context)

      Report
      |> Ash.Query.filter(id == ^report.id)
      |> Ash.Query.for_read(:open, %{}, actor: actor, context: context)
      |> Ash.read_one!()

      assert [written] = entries(credential)
      assert written.context == context

      assert [_created, read] = entries(dossier)
      assert read.action_type == :read
      assert read.context == context

      # `Report` does not list `:ticket`, so the same context keeps only
      # `action_source` there.
      assert [_created, report_written, report_read] = report_entries(report)
      assert report_written.context == %{action_source: "support"}
      assert report_read.context == %{action_source: "support"}
    end

    for {kind, value} <- [
          map: Macro.escape(%{id: "T-1042"}),
          list: ["T-1042"],
          struct: Macro.escape(URI.parse("https://tickets.test/T-1042"))
        ] do
      test "drops a listed key holding a #{kind}", %{actor: actor} do
        record =
          Credential
          |> Ash.Changeset.for_create(:create, %{name: "Gateway"},
            actor: actor,
            context: %{action_source: "support", ticket: unquote(value)}
          )
          |> Ash.create!()

        assert [entry] = entries(record)
        assert entry.context == %{action_source: "support"}
        refute inspect(entry) =~ "T-1042"
      end
    end

    test "keeps none of Ash's own keys", %{actor: actor} do
      record =
        Credential
        |> Ash.Changeset.for_create(:create, %{name: "Gateway"}, actor: actor)
        |> Ash.create!()

      record
      |> Ash.Changeset.for_update(:update, %{name: "Renamed"}, actor: actor)
      |> Ash.update!()

      for entry <- entries(record) do
        refute Map.has_key?(entry.context, :changed?)
        assert entry.context == %{}
      end
    end
  end

  # A file-producing action that only records that it happened, on a resource
  # with auditing, bookkeeping stamps, versioning and an update policy all on:
  # the row names the actor and holds the argument the hook set, the lock, the
  # stamp and the timestamp stay where they were, and the mark reaches the
  # caller. Removing the stamp's, the lock's or the audit's handling of a write
  # that changes nothing fails it.
  describe "a download that changes nothing" do
    setup %{actor: creator} do
      reader = Actor |> Ash.Changeset.for_create(:create, %{name: "Reader"}) |> Ash.create!()

      report =
        Report
        |> Ash.Changeset.for_create(:create, %{title: "Quarterly", reader_ids: [reader.id]},
          actor: creator
        )
        |> Ash.create!()

      %{creator: creator, reader: reader, report: report}
    end

    test "is audited, leaves bookkeeping alone and is marked",
         %{creator: creator, reader: reader, report: report} do
      assert {:ok, exported} = export(report, reader)

      assert exported.__metadata__.ash_quick_download == %{
               data: "zq-report-body",
               filename: "report.csv",
               content_type: "application/octet-stream"
             }

      for result <- [exported, Ash.get!(Report, report.id)] do
        assert result.version == report.version
        assert result.updated_by_id == creator.id
        assert result.updated_at == report.updated_at
      end

      assert [_created, entry] = report_entries(report)
      assert entry.action_name == :export
      assert entry.actor_id == reader.id
      assert entry.arguments[:filename] == "report.csv"
    end

    test "refused by the policy, errors with no mark and no row", %{report: report} do
      outsider = Actor |> Ash.Changeset.for_create(:create, %{name: "Outsider"}) |> Ash.create!()

      assert {:error, %Ash.Error.Forbidden{}} = export(report, outsider)
      assert [created] = report_entries(report)
      assert created.action_name == :create
    end

    test "still succeeds from a copy someone else has since edited",
         %{creator: creator, reader: reader, report: report} do
      edited =
        report
        |> Ash.Changeset.for_update(:update, %{title: "Quarterly, revised"}, actor: creator)
        |> Ash.update!()

      assert edited.version != report.version

      assert {:ok, exported} = export(report, reader)
      assert exported.__metadata__.ash_quick_download.filename == "report.csv"
      assert Ash.get!(Report, report.id).version == edited.version
    end
  end
end
