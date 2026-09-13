defmodule AshQuick.Impersonation.Transformer do
  @moduledoc false
  # Adds the update action both ends of an impersonation authorize against, to
  # the configured `:actor_resource` and to nothing else.
  #
  # It writes nothing — `AshQuick.Impersonation.NoOp` hands the record straight
  # back — so what it is for is the two things running an action gets: the
  # resource's policy decides who may impersonate whom, and the audit log
  # records that they did. Nothing else about an impersonation is written
  # anywhere, so that entry is the whole trail.
  #
  # Generating it offers nothing by itself. An action nothing authorizes is one
  # nobody can run, and a host that wants impersonation still has to wire the
  # token, the register and the page. What the resource gains by standing still
  # is the place for its policy to say who may stand in for whom — including
  # nobody.
  #
  # Add-if-absent, like the rest of AshQuick's generated pieces: a resource that
  # writes its own action of that name keeps it whole.
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias AshQuick.Impersonation

  @impl true
  def after?(AshQuick.Audit.Transformer), do: true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    action = Impersonation.action()

    if Impersonation.resource?(dsl_state) and is_nil(Ash.Resource.Info.action(dsl_state, action)) do
      Builder.add_action(dsl_state, :update, action,
        accept: [],
        # The manual implementation is reached through the non-atomic path, and
        # an atomic version of "change nothing" would skip the changeset the
        # audit entry is built from.
        require_atomic?: false,
        manual: AshQuick.Impersonation.NoOp,
        description: "Authorizes and records one actor standing in for this one. Writes nothing."
      )
    else
      {:ok, dsl_state}
    end
  end
end
