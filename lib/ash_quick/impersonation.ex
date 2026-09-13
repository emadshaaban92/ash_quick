defmodule AshQuick.Impersonation do
  @moduledoc """
  What AshQuick knows about impersonation before it looks at any resource.

  There is nothing to declare. An impersonation resolves a token back to an
  actor, so the only resource it can ever name is the one an actor is resolved
  from — the configured `:actor_resource`. That resource is therefore where
  `AshQuick.Impersonation.Transformer` generates the action and where
  `AshQuick.Impersonation.Verifier` holds the two requirements that make it
  accountable, and a per-resource flag could only restate the answer or
  contradict it.

  Everything here is the shared reader for that: `resource?/1` is the question
  both the transformer and the verifier ask while a resource compiles,
  `resource!/0` the one `AshQuick.Impersonation.Token` and
  `AshQuick.LiveView.BrowserSessionsLive` ask on a request, and `action/0` the
  name all four spell.
  """

  alias AshQuick.Config

  @action :impersonate

  @doc """
  The update action both ends of an impersonation authorize against.

  Fixed rather than configurable: it is generated add-if-absent, so a host that
  means something else by `:impersonate` keeps its own action under that name
  and impersonation authorizes against it.
  """
  def action, do: @action

  @doc """
  Whether `dsl_or_resource` is the resource impersonation is generated on.

  Takes an in-flight DSL state or a compiled module, so the transformer and the
  verifier ask it the same way. The comparison is between two atoms and loads
  nothing, so a resource asking it while the actor resource is still compiling
  — including the actor resource asking about itself — cannot deadlock.
  """
  def resource?(dsl_or_resource) do
    case Config.actor_resource() do
      nil -> false
      actor_resource -> module(dsl_or_resource) == actor_resource
    end
  end

  @doc """
  The resource an impersonation names a record of.

  Raises unless it both is configured and carries the generated action, which
  are the two ways a host can arrive here with nothing to authorize against.
  The second is reachable through a gap in an otherwise complete wiring:
  `AshQuick.Bookkeeping.Verifier` already refuses an actor resource without the
  extension, but only for a host whose resources stamp an actor at all. Without
  this the miss would surface as `Ash.can?/3` raising `NoSuchAction`, naming the
  action rather than the resource that was supposed to carry it.
  """
  def resource! do
    resource = Config.actor_resource() || raise ArgumentError, unconfigured()

    if offers?(resource) do
      resource
    else
      raise ArgumentError, unavailable(resource)
    end
  end

  defp offers?(resource) do
    Ash.Resource.Info.resource?(resource) and
      not is_nil(Ash.Resource.Info.action(resource, @action))
  end

  defp module(dsl_state) when is_map(dsl_state) do
    Spark.Dsl.Transformer.get_persisted(dsl_state, :module)
  end

  defp module(resource) when is_atom(resource), do: resource

  defp unconfigured do
    """
    Impersonation resolves a token back to an actor, so it needs to know what \
    an actor is:

        config :ash_quick, actor_resource: MyApp.Accounts.User
    """
  end

  defp unavailable(resource) do
    """
    #{inspect(resource)} is the configured `:actor_resource`, so AshQuick \
    generates its `#{inspect(@action)}` action — and it does not have one, which \
    means no transformer ran on it.

    Carry the extension on the actor resource:

        use Ash.Resource,
          extensions: [AshQuick, ...]
    """
  end
end
