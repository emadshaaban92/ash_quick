defmodule AshQuick.TransformerOrderTest do
  @moduledoc """
  The order AshQuick's own changes land in a resource's change list: the audit
  change, then the actor stamps, then the optimistic lock.

  Each of the three transformers that append them asks to run before
  everything, and Spark adds no edge between two transformers that both ask
  that. Their order was then whatever Spark's graph walk happened to pick, not
  anything a transformer declared, so it is pinned here twice: in Spark's sort,
  whatever order the transformers are listed in, and in a resource's changes.
  """
  use ExUnit.Case, async: true

  alias AshQuick.Test.Bookkeeping.Stamped

  @pinned [
    AshQuick.Audit.Transformer,
    AshQuick.Bookkeeping.Transformer,
    AshQuick.Versioning.Transformer
  ]

  test "Spark sorts the three in one order, however they are listed" do
    transformers = AshQuick.transformers() ++ Ash.Resource.Dsl.transformers()

    for listed <- [transformers, Enum.reverse(transformers) | shuffles(transformers, 20)] do
      sorted = Spark.Dsl.Transformer.sort(listed)
      assert Enum.filter(sorted, &(&1 in @pinned)) == @pinned
    end
  end

  test "a resource's changes run the audit, then the stamps, then the lock" do
    changes = Stamped |> Ash.Resource.Info.changes() |> Enum.map(&elem(&1.change, 0))

    audit = index!(changes, AshQuick.Audit.Change)
    stamp = index!(changes, AshQuick.Bookkeeping.StampWriter)
    lock = index!(changes, AshQuick.Versioning.Lock)

    assert audit < stamp
    assert stamp < lock
  end

  defp shuffles(list, count), do: for(_ <- 1..count, do: Enum.shuffle(list))

  defp index!(changes, module) do
    Enum.find_index(changes, &(&1 == module)) || flunk("#{inspect(module)} is not attached")
  end
end
