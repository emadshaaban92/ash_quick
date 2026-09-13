defmodule AshQuick.Audit.ActorError do
  @moduledoc """
  An audited write whose actor the entry cannot name.

  An audit entry is a statement about who changed something, so AshQuick needs
  an id to point the store's `actor_id` at. It takes one off an actor that has
  an `:id`, and takes a bare id as itself — Ash accepts either as an actor, and
  a caller that already holds the id passes it rather than reading the record
  back.

  Anything else — an atom standing for "the system", a map of claims, a
  struct with no id — cannot be named, and a row saying nobody did it is the
  entry somebody will come looking for. A write with no actor at all is
  different and records nothing: there, nobody *did* act.
  """

  defexception [:resource, :actor]

  @impl true
  def exception(opts) do
    %__MODULE__{resource: opts[:resource], actor: opts[:actor]}
  end

  @impl true
  def message(%__MODULE__{resource: resource, actor: actor}) do
    """
    #{inspect(resource)}: the audit entry cannot name the actor it was written by.

    AshQuick was handed:

        #{inspect(actor)}

    An entry names who made the change, so the actor has to carry an `:id`, or \
    be one. Pass the record (or its id) as the actor, or pass no actor at all \
    for a write nobody is behind — that one records nothing rather than \
    recording nobody.
    """
  end
end
