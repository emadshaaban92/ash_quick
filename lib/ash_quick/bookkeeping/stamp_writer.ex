defmodule AshQuick.Bookkeeping.StampWriter do
  @moduledoc false
  # Stamps the actor into a `belongs_to` on an update, but only when the update
  # is meaningful — when it changes something besides bookkeeping, as
  # `AshQuick.Bookkeeping.Meaningful` decides it, the same answer
  # `AshQuick.Versioning.Lock` bumps `version` on.
  #
  # `relate_actor(:updated_by)` alone stamps every update, so a write that
  # changes nothing (a print or a download that only records it happened, a
  # form resubmitted unchanged) named whoever ran it as the record's last
  # writer. The stamp is an attribute write, so it then counted as a change and
  # moved `updated_at` too. Stamped only on a meaningful write, a no-op write
  # changes nothing at all: Ash moves an `update_timestamp` only when the write
  # changes something, so `updated_by`, `updated_at` and `version` move
  # together or not at all.
  #
  # Otherwise it behaves as `relate_actor/1` with `allow_nil?: false` does on a
  # `belongs_to`: no actor is an error on every update, meaningful or not, and a
  # stamped record comes back with the relationship set to the actor.
  #
  # The two paths decide where the final write is visible, as the lock does.
  # In memory the decision is a `before_action` appended last. On the atomic
  # path it is an expression against the row — `if <meaningful> do ^actor_id
  # else updated_by_id end` — so on a write that changes nothing the column is
  # set to what it holds, and Ash's own comparison leaves `updated_at` alone. It
  # sees what the lock sees and has the same limit: a global change another
  # extension appends after AshQuick's can write an atomic it never compared.
  #
  # `ignore` names attributes besides bookkeeping that do not make a write
  # meaningful: the lock's counter, which the lock sets after this has run on
  # the atomic path and which no meaningful write would be without anyway.
  use Ash.Resource.Change

  require Ash.Expr

  alias Ash.Error.Changes.InvalidRelationship
  alias AshQuick.Bookkeeping.Meaningful

  @impl true
  def change(changeset, opts, %{actor: actor}) do
    relationship = relationship(changeset, opts)

    case actor do
      nil ->
        no_actor(changeset, relationship)

      actor ->
        actor_id = actor_id(actor, relationship)

        Ash.Changeset.before_action(
          changeset,
          &stamp_if_meaningful(&1, relationship, actor, actor_id, opts),
          prepend?: false
        )
    end
  end

  @impl true
  def atomic(changeset, opts, %{actor: actor}) do
    relationship = relationship(changeset, opts)

    case actor do
      nil ->
        {:error, no_actor_error(relationship)}

      actor ->
        actor_id = actor_id(actor, relationship)
        source = relationship.source_attribute

        case Meaningful.condition(changeset, ignore(opts)) do
          nil ->
            {:ok, changeset}

          true ->
            {:atomic, %{source => actor_id}}

          condition ->
            {:atomic,
             %{
               source =>
                 Ash.Expr.expr(
                   if ^condition do
                     ^actor_id
                   else
                     ^Ash.Expr.ref(source)
                   end
                 )
             }}
        end
    end
  end

  defp stamp_if_meaningful(changeset, relationship, actor, actor_id, opts) do
    if Meaningful.meaningful?(changeset, ignore(opts)) do
      changeset
      |> Ash.Changeset.force_change_attribute(relationship.source_attribute, actor_id)
      |> Ash.Changeset.after_action(fn _changeset, record ->
        {:ok, Map.put(record, relationship.name, actor)}
      end)
    else
      changeset
    end
  end

  defp relationship(changeset, opts) do
    Ash.Resource.Info.relationship(changeset.resource, Keyword.fetch!(opts, :relationship))
  end

  defp ignore(opts), do: Keyword.get(opts, :ignore, [])

  # What `relate_actor/1` writes: the actor's destination attribute, or the
  # actor itself when it is already a key rather than a record.
  defp actor_id(actor, relationship) when is_map(actor),
    do: Map.get(actor, relationship.destination_attribute)

  defp actor_id(actor, _relationship), do: actor

  defp no_actor(changeset, relationship) do
    Ash.Changeset.add_error(changeset, no_actor_error(relationship))
  end

  # The words `relate_actor/1` uses, so a host matching on them sees no change.
  defp no_actor_error(relationship) do
    InvalidRelationship.exception(
      relationship: relationship.name,
      message: "could not relate to actor, as no actor was found (and :allow_nil? is false)"
    )
  end
end
