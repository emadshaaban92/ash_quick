defmodule AshQuick.Audit.Transformer do
  @moduledoc false
  # Attaches `AshQuick.Audit.Change` to every create, update and destroy of a
  # resource, unless it declared `audit do enabled? false end`.
  #
  # Two resources are never attached to, whatever they declare, because neither
  # can record itself: the audit store, whose own writes are the entries and
  # would recurse, and an embedded resource, which has no row of its own for an
  # entry to name — it is written as part of its parent's, and that is the write
  # the log records.
  #
  # `only_when_valid?` so a write that never happened records nothing.
  use Spark.Dsl.Transformer

  alias Ash.Resource.Dsl
  alias AshQuick.Audit.Declaration
  alias Spark.Dsl.Transformer

  # The change is appended before anything else appends its own, which is what
  # puts the audit entry ahead of the actor stamps and the optimistic lock in
  # every resource's change list.
  @impl true
  def after?(_), do: false

  @impl true
  def before?(_), do: true

  @impl true
  def transform(dsl_state) do
    if Declaration.audits?(dsl_state) do
      {:ok, change} =
        Transformer.build_entity(Dsl, [:changes], :change,
          change: AshQuick.Audit.Change,
          on: [:create, :update, :destroy],
          only_when_valid?: true
        )

      {:ok, Transformer.add_entity(dsl_state, [:changes], change, type: :append)}
    else
      {:ok, dsl_state}
    end
  end
end
