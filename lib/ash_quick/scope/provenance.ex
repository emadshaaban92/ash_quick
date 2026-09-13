defmodule AshQuick.Scope.Provenance do
  @moduledoc """
  What AshQuick knows about *who* is acting, beyond the actor Ash already
  carries.

  One struct, produced from a scope by `AshQuick.Scope.provenance/1` and
  carried into every action's shared context by the `get_context/1` that
  `use AshQuick.Scope` generates. Audit reads it back off a changeset, an
  impersonation banner reads it off the scope, and both get the same shape.

  ## Fields

    * `:real_actor` — the human behind the actor. Equal to the actor unless
      someone is impersonating, which is why it is never `nil` when the actor
      isn't: a host with no impersonation has the two always equal rather than
      one of them empty.
    * `:impersonating?` — whether the two differ.
    * `:ip` — where the request came from, or `nil` off a request (a job, a
      console).
    * `:timezone` / `:locale` — the actor's own, or `nil` to mean the host
      states none and the application-wide `AshQuick.Config` values apply.
      Read them through `AshQuick.Scope.timezone/1` and
      `AshQuick.Scope.locale/1`, which apply that fallback.
  """

  defstruct [:real_actor, :ip, :timezone, :locale, impersonating?: false]

  # The one shared-context key AshQuick claims, namespaced so a host's own
  # shared keys and a per-call `context:` can never collide with it. It lives
  # here rather than on `AshQuick.Scope` so the implementations that read it
  # back off a changeset don't have to depend on the module that writes it.
  @context_key :ash_quick

  @doc """
  The key under an action's shared context where the provenance is carried.
  """
  def context_key, do: @context_key

  @doc """
  Reads a field of the provenance a scope left in `shared`, or `:error` when
  the scope left none — the answer `AshQuick.Scope.ToProvenance` getters give.
  """
  def fetch(%{@context_key => %__MODULE__{} = provenance}, field),
    do: Map.fetch(provenance, field)

  def fetch(_shared, _field), do: :error
end
