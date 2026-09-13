defmodule AshQuick.BookkeepingTest do
  @moduledoc """
  What the bookkeeping declaration is *for*: deriving the set of changes an
  update may make without bumping the optimistic lock.

  That list used to be a single global one — `[:updated_at, :created_at,
  :updated_by_id, :created_by_id]` — applied to every resource whether or not it
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

  alias AshQuick.Config
  alias AshQuick.Test.Bookkeeping.AllFour
  alias AshQuick.Test.Bookkeeping.CreateOnly
  alias AshQuick.Test.Bookkeeping.HandWrittenActorColumn
  alias AshQuick.Test.Bookkeeping.TimestampsOnly
  alias AshQuick.Test.PlainRecord

  describe "the derived ignore list" do
    test "covers both halves of a changeset for a resource carrying all four" do
      # The lock drops from `changeset.attributes` and `changeset.relationships`
      # separately, so an actor has to appear in both lists — as its column in
      # one and its relationship in the other.
      assert Config.versioning_ignored_attributes(AllFour) ==
               [:created_at, :updated_at, :created_by_id, :updated_by_id]

      assert Config.versioning_ignored_relationships(AllFour) == [:created_by, :updated_by]
    end

    test "is narrower than the global list where a resource carries less" do
      # Without this the assertion above would pass just as well against a
      # derivation that had quietly kept the global list.
      assert Config.versioning_ignored_attributes(CreateOnly) == [:created_at, :created_by_id]
      assert Config.versioning_ignored_relationships(CreateOnly) == [:created_by]

      assert Config.versioning_ignored_attributes(TimestampsOnly) == [:created_at, :updated_at]
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
               [:created_by_id, :updated_by_id]
    end
  end

  describe "a resource without the extension" do
    test "reads as carrying no bookkeeping at all, rather than as the defaults" do
      # Spark hands a section's defaults back for any module at all, so without
      # the extension check every module in the app would claim all four.
      refute AshQuick in Spark.extensions(PlainRecord)
      assert Ash.Resource.Info.attribute(PlainRecord, :created_at)

      assert AshQuick.Info.bookkeeping(PlainRecord) == nil
      assert AshQuick.Info.timestamp_fields(PlainRecord) == []
      assert AshQuick.Info.actor_fields(PlainRecord) == []
      assert AshQuick.Info.actor_attributes(PlainRecord) == []
    end
  end
end
