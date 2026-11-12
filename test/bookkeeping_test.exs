defmodule AshQuick.BookkeepingTest do
  @moduledoc """
  What the bookkeeping declaration is *for*: deriving the set of changes an
  update may make without bumping the optimistic lock.

  That list used to be a single global one — `[:updated_at, :created_at,
  :updated_by_id, :inserted_by_id]` — applied to every resource whether or not it
  had those columns. Deriving it per resource is strictly more precise, but
  precision is the risk: a column the old list ignored blindly and the new one
  fails to derive starts counting as a meaningful change, and the resource
  begins bumping `version` on writes that were no-ops before. Nothing raises.

  So the derivation is pinned per shape rather than per resource — one fixture
  for each way a resource can carry less than all four. A host additionally
  sweeps its own resources for the regression above, where the population is
  what makes the sweep worth running.

  The lock's behaviour under a bookkeeping-only write is a host's to drive: a
  user resubmitting an unchanged form is that write.
  """
  use ExUnit.Case, async: true

  require Ash.Query

  alias AshQuick.Config
  alias AshQuick.Test.Actor
  alias AshQuick.Test.AuditLog
  alias AshQuick.Test.Bookkeeping.AllFour
  alias AshQuick.Test.Bookkeeping.CreateOnly
  alias AshQuick.Test.Bookkeeping.Stamped
  alias AshQuick.Test.Bookkeeping.HandWrittenActorColumn
  alias AshQuick.Test.Bookkeeping.TimestampsOnly
  alias AshQuick.Test.PlainRecord

  describe "the derived ignore list" do
    test "covers both halves of a changeset for a resource carrying all four" do
      # The lock drops from `changeset.attributes` and `changeset.relationships`
      # separately, so an actor has to appear in both lists — as its column in
      # one and its relationship in the other.
      assert Config.versioning_ignored_attributes(AllFour) ==
               [:inserted_at, :updated_at, :inserted_by_id, :updated_by_id]

      assert Config.versioning_ignored_relationships(AllFour) == [:inserted_by, :updated_by]
    end

    test "is narrower than the global list where a resource carries less" do
      # Without this the assertion above would pass just as well against a
      # derivation that had quietly kept the global list.
      assert Config.versioning_ignored_attributes(CreateOnly) == [:inserted_at, :inserted_by_id]
      assert Config.versioning_ignored_relationships(CreateOnly) == [:inserted_by]

      assert Config.versioning_ignored_attributes(TimestampsOnly) == [:inserted_at, :updated_at]
      assert Config.versioning_ignored_relationships(TimestampsOnly) == []
    end
  end

  describe "actor attributes" do
    test "are read off the relationship, not built from its name" do
      # The relationship declares `define_attribute? false` over a hand-written
      # `:updated_by_id` carrying `always_select?: true`. A `:"#{name}_id"`
      # guess would land on the same atom here by luck; reading
      # `source_attribute` is what makes it correct.
      relationship = Ash.Resource.Info.relationship(HandWrittenActorColumn, :updated_by)

      refute relationship.define_attribute?

      assert Ash.Resource.Info.attribute(HandWrittenActorColumn, :updated_by_id).always_select?

      assert AshQuick.Info.actor_attributes(HandWrittenActorColumn) ==
               [:inserted_by_id, :updated_by_id]
    end
  end

  describe "a resource without the extension" do
    test "reads as carrying no bookkeeping at all, rather than as the defaults" do
      # Spark hands a section's defaults back for any module at all, so without
      # the extension check every module in the app would claim all four.
      refute AshQuick in Spark.extensions(PlainRecord)
      assert Ash.Resource.Info.attribute(PlainRecord, :inserted_at)

      assert AshQuick.Info.bookkeeping(PlainRecord) == nil
      assert AshQuick.Info.timestamp_fields(PlainRecord) == []
      assert AshQuick.Info.actor_fields(PlainRecord) == []
      assert AshQuick.Info.actor_attributes(PlainRecord) == []
    end
  end

  describe "the updated_by stamp" do
    # Mona created the record; Ahmed is the one who writes to it afterwards. A
    # stamp by the creator would match what is already there, so every write
    # here is by someone else.
    setup do
      mona = actor("Mona")
      ahmed = actor("Ahmed")

      record =
        Stamped
        |> Ash.Changeset.for_create(:create, %{name: "Invoice"}, actor: mona)
        |> Ash.create!()

      %{mona: mona, ahmed: ahmed, record: record}
    end

    test "each action runs on the path its name says", %{record: record} do
      # Without this the atomic tests below would pass just as well in memory.
      for action <- [:rename, :download] do
        assert %Ash.Changeset{} =
                 Ash.Changeset.fully_atomic_changeset(Stamped, action, %{}, data: record)
      end

      for action <- [:rename_in_memory, :download_in_memory, :exclaim_in_memory] do
        assert {:not_atomic, _reason} =
                 Ash.Changeset.fully_atomic_changeset(Stamped, action, %{}, data: record)
      end
    end

    for action <- [:download, :download_in_memory] do
      test "#{action}, which writes nothing, leaves updated_by, updated_at and version alone",
           %{mona: mona, ahmed: ahmed, record: record} do
        downloaded = update!(record, unquote(action), %{}, ahmed)

        for result <- [downloaded, reread(record)] do
          assert_untouched(result, record, mona)
        end
      end

      test "#{action} is still audited, under the actor who ran it",
           %{ahmed: ahmed, record: record} do
        update!(record, unquote(action), %{}, ahmed)

        assert [_created, entry] = entries(record)
        assert entry.action_name == unquote(action)
        assert entry.actor_id == ahmed.id
      end

      test "#{action} still needs an actor", %{record: record} do
        assert {:error, error} =
                 record
                 |> Ash.Changeset.for_update(unquote(action), %{})
                 |> Ash.update()

        assert Exception.message(error) =~ "could not relate to actor"
      end
    end

    for action <- [:rename, :rename_in_memory] do
      test "#{action} stamps the writer and moves updated_at and version",
           %{ahmed: ahmed, record: record} do
        renamed = update!(record, unquote(action), %{name: "Invoice 2"}, ahmed)

        for result <- [renamed, reread(record)] do
          assert result.name == "Invoice 2"
          assert result.updated_by_id == ahmed.id
          assert DateTime.after?(result.updated_at, record.updated_at)
          assert result.version == record.version + 1
        end

        # In memory the record comes back with the relationship set, as
        # `relate_actor` leaves it; neither sets it on the atomic path.
        if unquote(action) == :rename_in_memory do
          assert renamed.updated_by.id == ahmed.id
        end
      end

      # A form resubmitted unchanged: on the atomic path the name still arrives
      # as an atomic, so this is the row comparison and not an empty changeset.
      test "#{action} to the value the record already holds stamps nothing",
           %{mona: mona, ahmed: ahmed, record: record} do
        resubmitted = update!(record, unquote(action), %{name: "Invoice"}, ahmed)

        for result <- [resubmitted, reread(record)] do
          assert_untouched(result, record, mona)
        end
      end
    end

    # Memory cannot compare an expression with the row, so it counts as a
    # change: the write is stamped and locked rather than let through as Mona's.
    test "an in-memory write through an expression stamps the writer and takes the lock",
         %{ahmed: ahmed, record: record} do
      exclaimed = update!(record, :exclaim_in_memory, %{}, ahmed)

      for result <- [exclaimed, reread(record)] do
        assert result.name == "Invoice!"
        assert result.updated_by_id == ahmed.id
        assert DateTime.after?(result.updated_at, record.updated_at)
        assert result.version == record.version + 1
      end
    end

    # Versioning declines an atomic write by query, so this runs down whichever
    # strategy Ash falls back to; the stamp has to hold on each.
    test "a bulk update stamps only the rows it changes",
         %{mona: mona, ahmed: ahmed, record: record} do
      other =
        Stamped
        |> Ash.Changeset.for_create(:create, %{name: "Receipt"}, actor: mona)
        |> Ash.create!()

      assert %Ash.BulkResult{status: :success} =
               Stamped
               |> Ash.Query.filter(id in ^[record.id, other.id])
               |> Ash.bulk_update(:rename, %{name: "Invoice"},
                 actor: ahmed,
                 strategy: [:atomic, :atomic_batches, :stream],
                 authorize?: false,
                 return_errors?: true
               )

      assert_untouched(reread(record), record, mona)

      changed = reread(other)
      assert changed.name == "Invoice"
      assert changed.updated_by_id == ahmed.id
      assert DateTime.after?(changed.updated_at, other.updated_at)
    end
  end

  defp assert_untouched(result, record, writer) do
    assert result.updated_by_id == writer.id
    assert result.updated_at == record.updated_at
    assert result.version == record.version
  end

  defp reread(record), do: Ash.get!(Stamped, record.id, authorize?: false)

  defp actor(name) do
    Actor
    |> Ash.Changeset.for_create(:create, %{name: name})
    |> Ash.create!()
  end

  defp update!(record, action, input, actor) do
    record
    |> Ash.Changeset.for_update(action, input, actor: actor)
    |> Ash.update!()
  end

  defp entries(record) do
    AuditLog
    |> Ash.Query.filter(resource_id == ^record.id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!()
  end
end
