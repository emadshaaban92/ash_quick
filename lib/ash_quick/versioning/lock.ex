defmodule AshQuick.Versioning.Lock do
  @moduledoc false
  # Single-mechanism optimistic lock for declared versioning.
  #
  # Unlike `Ash.Resource.Change.OptimisticLock`, which decides whether to lock at
  # the *change phase* (before `before_action` hooks run), this change makes the
  # decision in a `before_action` registered last — so it sees the FINAL
  # changeset. That closes two holes the change-phase decision cannot:
  #
  #   * Under-lock: a `before_action` that injects the only real change used to
  #     write the row with no lock at all (the change-phase guard saw an empty
  #     changeset and skipped the lock). Now that change is visible, so the write
  #     is locked.
  #   * Over-lock churn / self-referential collisions: a changeset that is a
  #     genuine no-op once all `before_action`s have run gets no filter and no
  #     bump, so an orchestration update that doesn't touch its own record can't
  #     collide with a nested update that bumps the same record mid-action.
  #
  # This requires the action to run non-atomically (the decision needs the
  # in-memory final changeset). `AshQuick.Versioning.Transformer` forces
  # `require_atomic? false` on every `:update`/`:destroy` action of a versioned
  # resource; `atomic/3` here returns `:not_atomic` as a backstop.
  #
  # The locked attribute arrives in `opts` — the transformer resolved it from the
  # resource's declaration, so nothing here has to look it up per changeset.
  use Ash.Resource.Change

  require Ash.Expr

  @impl true
  def change(changeset, opts, _context) do
    attribute = Keyword.fetch!(opts, :attribute)

    Ash.Changeset.before_action(changeset, &apply_lock_if_meaningful(&1, attribute),
      prepend?: false
    )
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:not_atomic,
     "AshQuick versioning decides the optimistic lock on the final changeset in a before_action"}
  end

  defp apply_lock_if_meaningful(changeset, attribute) do
    if meaningful?(changeset, attribute) do
      current = Map.get(changeset.data, attribute)

      changeset
      |> Ash.Changeset.filter(Ash.Expr.expr(^Ash.Expr.ref(attribute) == ^current))
      |> Ash.Changeset.force_change_attribute(attribute, current + 1)
    else
      changeset
    end
  end

  defp meaningful?(%{resource: resource} = changeset, attribute) do
    ignored_attributes = [attribute | AshQuick.Config.versioning_ignored_attributes(resource)]

    attributes = Map.drop(changeset.attributes, ignored_attributes)

    relationships =
      Map.drop(
        changeset.relationships,
        AshQuick.Config.versioning_ignored_relationships(resource)
      )

    not (attributes == %{} and relationships == %{})
  end
end
