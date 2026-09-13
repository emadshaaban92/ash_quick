defprotocol AshQuick.Scope.ToProvenance do
  @moduledoc """
  Extracts actor provenance from a scope — strictly additive over
  `Ash.Scope.ToOpts`.

  Ash's protocol answers actor, tenant, context, tracer and `authorize?`. This
  one answers the five things AshQuick needs and Ash has no standard place for:
  the real actor behind an impersonation, whether one is in progress, the
  request's IP, and the actor's timezone and locale.

  It is deliberately a second protocol rather than a fork of Ash's. A scope
  implements both, `AshQuick.Scope` reads both, and if Ash ever standardises
  `real_actor` this protocol can delegate to it instead of competing with it.

  Do not write these implementations by hand — `use AshQuick.Scope` generates
  this one and the `Ash.Scope.ToOpts` one together, and the whole point of the
  macro is that a field it cannot derive fails the compile instead of returning
  `nil` forever.

  Every getter returns `{:ok, value}` or `:error`. `:error` means the host
  states nothing about that field, and `AshQuick.Scope` applies the documented
  default — which is not the same as `{:ok, nil}`, an explicit "there is none".
  """

  @doc "The human behind the actor. `:error` falls back to the actor itself."
  def get_real_actor(scope)

  @doc "Whether the actor and the real actor differ. `:error` derives it."
  def get_impersonating?(scope)

  @doc "The IP the request came from. `:error` falls back to `nil`."
  def get_ip(scope)

  @doc "The actor's timezone. `:error` falls back to `AshQuick.Config.timezone/0`."
  def get_timezone(scope)

  @doc "The actor's locale. `:error` falls back to `AshQuick.Config.locale/0`."
  def get_locale(scope)
end

# Ash leaves the scope at the front door: past it, code holds a changeset, a
# query or a hook's context instead. These read the provenance back out of the
# shared context the generated `get_context/1` put it in, so `provenance/1`
# answers the same thing on either side of that door — which is what lets audit
# record who really acted while holding nothing but a changeset.
defimpl AshQuick.Scope.ToProvenance, for: [Ash.Changeset, Ash.Query, Ash.ActionInput] do
  alias AshQuick.Scope.Provenance

  def get_real_actor(%{context: context}), do: Provenance.fetch(context[:shared], :real_actor)

  def get_impersonating?(%{context: context}),
    do: Provenance.fetch(context[:shared], :impersonating?)

  def get_ip(%{context: context}), do: Provenance.fetch(context[:shared], :ip)
  def get_timezone(%{context: context}), do: Provenance.fetch(context[:shared], :timezone)
  def get_locale(%{context: context}), do: Provenance.fetch(context[:shared], :locale)
end

defimpl AshQuick.Scope.ToProvenance,
  for: [
    Ash.Resource.Actions.Implementation.Context,
    Ash.Resource.Calculation.Context,
    Ash.Resource.Change.Context,
    Ash.Resource.ManualCreate.Context,
    Ash.Resource.ManualCreate.BulkContext,
    Ash.Resource.ManualDestroy.Context,
    Ash.Resource.ManualDestroy.BulkContext,
    Ash.Resource.ManualUpdate.Context,
    Ash.Resource.ManualUpdate.BulkContext,
    Ash.Resource.ManualRelationship.Context,
    Ash.Resource.Preparation.Context,
    Ash.Resource.Validation.Context
  ] do
  alias AshQuick.Scope.Provenance

  def get_real_actor(%{source_context: shared}),
    do: Provenance.fetch(shared[:shared], :real_actor)

  def get_impersonating?(%{source_context: shared}),
    do: Provenance.fetch(shared[:shared], :impersonating?)

  def get_ip(%{source_context: shared}), do: Provenance.fetch(shared[:shared], :ip)
  def get_timezone(%{source_context: shared}), do: Provenance.fetch(shared[:shared], :timezone)
  def get_locale(%{source_context: shared}), do: Provenance.fetch(shared[:shared], :locale)
end

# `Ash.Scope.ToOpts` accepts a bare map as a scope, so this one does too — both
# the `%{shared: ...}` shape a hook is handed and the `%{context: %{shared: ...}}`
# one a subject carries.
defimpl AshQuick.Scope.ToProvenance, for: Map do
  alias AshQuick.Scope.Provenance

  def get_real_actor(map), do: Provenance.fetch(shared(map), :real_actor)
  def get_impersonating?(map), do: Provenance.fetch(shared(map), :impersonating?)
  def get_ip(map), do: Provenance.fetch(shared(map), :ip)
  def get_timezone(map), do: Provenance.fetch(shared(map), :timezone)
  def get_locale(map), do: Provenance.fetch(shared(map), :locale)

  defp shared(%{shared: shared}), do: shared
  defp shared(%{context: %{shared: shared}}), do: shared
  defp shared(_map), do: %{}
end
