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
  #
  # A resource listing `read_actions` also gets `AshQuick.Audit.Preparation`,
  # as a resource-wide preparation that checks the action's name itself rather
  # than one added to each listed action. That keeps this transformer free of
  # any ordering against the ones that build actions, and the check is one list
  # lookup on an unlisted read. A resource listing none gets nothing, so its
  # reads are exactly as they were.
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

      {:ok,
       dsl_state
       |> Transformer.add_entity([:changes], change, type: :append)
       |> add_read_preparation(Declaration.read_actions(dsl_state))}
    else
      {:ok, dsl_state}
    end
  end

  defp add_read_preparation(dsl_state, []), do: dsl_state

  defp add_read_preparation(dsl_state, actions) do
    {:ok, preparation} =
      Transformer.build_entity(Dsl, [:preparations], :prepare,
        preparation: {AshQuick.Audit.Preparation, actions: actions}
      )

    Transformer.add_entity(dsl_state, [:preparations], preparation, type: :append)
  end
end
