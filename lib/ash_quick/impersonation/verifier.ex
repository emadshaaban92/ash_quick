defmodule AshQuick.Impersonation.Verifier do
  @moduledoc false
  # Refuses to compile an actor resource that cannot carry impersonation
  # accountably.
  #
  # Impersonation is generated rather than asked for, so these are requirements
  # on the configured `:actor_resource` itself and not on a resource that opted
  # into anything. That is the honest shape: the escalation exists wherever an
  # actor can be resolved from, so a host cannot hold the action and decline
  # what makes it traceable — only decline to authorize it, which is a decision
  # its policy states.
  #
  # An impersonation writes nothing, so the audit entry the action leaves is the
  # only record that it ever happened — impersonation with auditing off is
  # untraceable privilege escalation, and the tab it starts can be somebody else
  # for the rest of the working day. That pairing is the reason the two features
  # ship in one package: two packages could only document it.
  #
  # Only that auditing is *on* is settled here. What it is written to is
  # `AshQuick.Audit.Verifier`'s, which runs first and already refuses a resource
  # whose store is missing or cannot take the row — turning audit on is
  # therefore what drags the store requirement in, rather than this verifier
  # restating it and reporting the same problem twice.
  #
  # The authorizer is the other half. The generated action's whole job is to be
  # authorized; on a resource with no authorizer it authorizes nothing, and
  # `Ash.can?/3` answering yes for everybody is also what puts it in front of
  # them, since QuickView offers every update action it says yes to.
  use Spark.Dsl.Verifier

  alias AshQuick.Audit.Declaration, as: Audit
  alias AshQuick.Impersonation
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    if Impersonation.resource?(dsl_state) do
      check(dsl_state)
    else
      :ok
    end
  end

  defp check(dsl_state) do
    cond do
      not Audit.audits?(dsl_state) -> {:error, error(dsl_state, unaudited())}
      not authorized?(dsl_state) -> {:error, error(dsl_state, unauthorized())}
      true -> :ok
    end
  end

  defp authorized?(dsl_state) do
    Ash.Policy.Authorizer in Verifier.get_persisted(dsl_state, :authorizers, [])
  end

  defp error(dsl_state, {problem, remedy}) do
    module = Verifier.get_persisted(dsl_state, :module)

    Spark.Error.DslError.exception(
      module: module,
      path: [:ash_quick, :impersonation],
      message: """
      #{inspect(module)} is the configured `:actor_resource`, so AshQuick generates \
      its `#{inspect(Impersonation.action())}` action — one privileged actor browsing \
      the application as another. And #{problem}

      #{remedy}
      """
    )
  end

  defp unaudited do
    {"""
     it is not audited.
     """,
     """
     An impersonation writes nothing to either record, so the entry the action \
     leaves is the only record there is that one person browsed as another. \
     Without it the escalation is untraceable.

     Stop excluding this resource from the audit log:

         ash_quick do
           audit do
             enabled? true
           end
         end
     """}
  end

  defp unauthorized do
    {"""
     nothing authorizes that action.
     """,
     """
     Being authorized is the whole of what it does, and on a resource with no \
     authorizer it authorizes nothing at all — every actor may stand in for \
     every other, and QuickView offers the action to all of them. Add one, and a \
     policy saying who may stand in for whom, or that nobody may:

         use Ash.Resource, authorizers: [Ash.Policy.Authorizer]

         policies do
           policy action(#{inspect(Impersonation.action())}) do
             authorize_if MyApp.Checks.ActorIsAdmin
           end
         end
     """}
  end
end
