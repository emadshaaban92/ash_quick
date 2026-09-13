defmodule AshQuick.Topics do
  @moduledoc """
  The PubSub topics AshQuick publishes and subscribes on.

  Both sides of liveness go through here. `AshQuick.PubSub.Transformer` builds a
  resource's publications from `collection/1`, and `AshQuick.LiveView.Liveness`
  builds a QuickView's subscriptions from the same function — so a page cannot
  listen on a topic the resource does not publish. A topic spelled out on either
  side could disagree with the other, and a subscription to a topic nobody
  publishes has no symptom: the page simply never updates.

  The prefix is declared in the resource's `ash_quick.liveness` block and
  defaults to its `short_name`.
  """

  @doc """
  Whether this resource publishes at all.

  False for a resource that does not carry the `AshQuick` extension, and for one
  that carries it with `enabled? false` — a resource wanting field restrictions
  without liveness, or one whose write volume makes broadcasting a bad trade.
  """
  def enabled?(resource) do
    AshQuick in Spark.extensions(resource) and
      Spark.Dsl.Extension.get_opt(resource, [:ash_quick, :liveness], :enabled?, true)
  end

  @doc """
  The resource-wide topic: `"product"`.

  Published for every create, update and destroy, so a subscriber hears about
  the whole collection — including records it has never seen.
  """
  def collection(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:ash_quick, :liveness], :prefix, nil) ||
      to_string(Ash.Resource.Info.short_name(resource))
  end

  @doc """
  One record's topic: `"product:<id>"`.

  Published alongside `collection/1` for the same changes. A subscriber that
  knows which records are on screen listens on these instead and hears nothing
  about the rest.
  """
  def record(resource, id) do
    "#{collection(resource)}#{delimiter()}#{id}"
  end

  @doc """
  The delimiter between a topic's segments.

  Matches `Ash.Notifier.PubSub`'s default, since that is what publishes.
  """
  def delimiter, do: ":"
end
