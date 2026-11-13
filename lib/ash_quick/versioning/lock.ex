defmodule AshQuick.Versioning.Lock do
  @moduledoc false
  # Single-mechanism optimistic lock for declared versioning.
  #
  # The lock is taken only for a *meaningful* write: one that changes an
  # attribute or relationship other than the counter itself and the ones
  # `AshQuick.Config.versioning_ignored_attributes/1` and
  # `versioning_ignored_relationships/1` name, as
  # `AshQuick.Bookkeeping.Meaningful` decides it. A destroy is always
  # meaningful.
  # Taking it means refusing the write unless the row still holds the version
  # the actor loaded, and bumping that version.
  #
  # The decision has to see the *final* write, or two things go wrong:
  #
  #   * Under-lock: a write whose only real change arrives after the decision
  #     goes through with no lock at all.
  #   * Over-lock churn / self-referential collisions: a write that ends up a
  #     genuine no-op still filters and bumps, so an orchestration update that
  #     doesn't touch its own record can collide with a nested update that bumps
  #     the same record mid-action.
  #
  # Ash runs an update or destroy down one of two paths, and the lock decides on
  # each where the final write is visible.
  #
  # Non-atomic (`change/3`): `before_action` hooks may still change the
  # changeset after every change has run, so the decision is a `before_action`
  # of its own, appended last, made against the in-memory changeset. A value
  # equal to what the record holds is not a change there — Ash drops it before
  # the write.
  #
  # Atomic (`atomic/3`): Ash refuses any `before_action` hook on this path, and
  # the lock is a global change appended after the resource's own, so by the
  # time it runs every change that can write has written into
  # `changeset.attributes` or `changeset.atomics`. What it cannot know is
  # whether those values differ from the row: Ash writes every accepted input
  # here, unchanged ones included, as atomics. So "meaningful" becomes an
  # expression the data layer evaluates against the row being written — the
  # same comparison Ash makes to decide whether an `update_default` such as
  # `updated_at` moves. When it holds, the write is filtered on the loaded
  # version and bumps it; when it does not, the row is written as it stands and
  # the version is left alone.
  #
  # Two limits of that path. The lock sees only what ran before it: a global
  # change another extension's transformer appends after AshQuick's can write
  # an atomic the lock never compared, where the in-memory path, deciding in
  # the last `before_action`, would have seen its result. And the condition
  # repeats every written expression, once in the counter's value and once in
  # the filter, so a fragment with a side effect such as `nextval(...)` is
  # evaluated more than once, and the statement grows with each field written.
  #
  # The atomic path declines (`:not_atomic`) a meaningful write whose changeset
  # carries `Ash.Changeset.OriginalDataNotAvailable`. That is a bulk write by
  # query, where nobody holds a copy, but it is also an `:atomic_batches` bulk
  # write over records somebody *did* load: Ash builds one changeset for every
  # batch and gives it none of their versions, and nothing on it says which of
  # the two it is. Declining keeps the per-record lock of the stream strategy
  # for both, which is what Ash's own `OptimisticLock` does.
  #
  # A record nobody loaded — a hand-built `%Post{id: id}`, or an identifier
  # given to `Ash.update_many/4`, which Ash turns into one — carries the
  # counter's default rather than a version anybody saw. There is no copy to be
  # stale, so its write is bumped without the check, on both paths. Ecto's
  # metadata is what tells it apart (`:built` until a data layer returns it),
  # together with the counter still holding its default: a built record given
  # a version of its own, `%Post{id: id, version: 3}`, is a copy held somewhere
  # else, and is checked like a loaded one. One given `version: 1` cannot be
  # told from one nobody filled in, so it goes unchecked.
  #
  # The locked attribute arrives in `opts` — the transformer resolved it from the
  # resource's declaration, so nothing here has to look it up per changeset.
  use Ash.Resource.Change

  require Ash.Expr

  alias AshQuick.Bookkeeping.Meaningful

  @impl true
  def change(changeset, opts, _context) do
    attribute = Keyword.fetch!(opts, :attribute)

    Ash.Changeset.before_action(changeset, &apply_lock_if_meaningful(&1, attribute),
      prepend?: false
    )
  end

  @impl true
  def atomic(changeset, opts, _context) do
    attribute = Keyword.fetch!(opts, :attribute)

    case changed_condition(changeset, attribute) do
      nil ->
        {:ok, changeset}

      condition ->
        case changeset.data do
          %Ash.Changeset.OriginalDataNotAvailable{} ->
            {:not_atomic,
             "AshQuick versioning cannot tell a bulk write by query from atomic batches " <>
               "over loaded records, whose versions it would have to check"}

          data ->
            {:ok, atomic_lock(changeset, attribute, loaded_version(data, attribute), condition)}
        end
    end
  end

  # A destroy is always meaningful. Its changeset carries no attribute changes,
  # so the emptiness test below would pass it through unlocked — and a destroy
  # against a copy somebody else has since updated is exactly the lost write
  # versioning exists to refuse. The bump is harmless on a hard destroy and
  # right on a soft one, which is an update underneath.
  defp apply_lock_if_meaningful(%{action_type: :destroy} = changeset, attribute) do
    apply_lock(changeset, attribute)
  end

  defp apply_lock_if_meaningful(changeset, attribute) do
    if Meaningful.meaningful?(changeset, [attribute]) do
      apply_lock(changeset, attribute)
    else
      changeset
    end
  end

  defp apply_lock(changeset, attribute) do
    case loaded_version(changeset.data, attribute) do
      nil ->
        Ash.Changeset.atomic_update(
          changeset,
          attribute,
          {:atomic, Ash.Expr.expr(^Ash.Expr.ref(attribute) + 1)}
        )

      current ->
        changeset
        |> Ash.Changeset.filter(Ash.Expr.expr(^Ash.Expr.ref(attribute) == ^current))
        |> Ash.Changeset.force_change_attribute(attribute, current + 1)
    end
  end

  defp loaded_version(%{__meta__: %{state: :built}} = data, attribute) do
    version = Map.get(data, attribute)

    if version == Ash.Resource.Info.attribute(data.__struct__, attribute).default,
      do: nil,
      else: version
  end

  defp loaded_version(data, attribute), do: Map.get(data, attribute)

  # The counter moves only when something meaningful does: the row's own value
  # is kept otherwise. The check is a filter rather than an `error(...)` in the
  # value, so a stale row is one the write does not match — which a single
  # update reports as `Ash.Error.Changes.StaleRecord`, and `Ash.update_many/4`
  # as a `StaleRecord` for that row alone, where an error raised inside its
  # `MERGE` would fail every row in the statement.
  defp atomic_lock(changeset, attribute, current, true) do
    changeset
    |> Ash.Changeset.atomic_update(
      attribute,
      {:atomic, Ash.Expr.expr(^Ash.Expr.ref(attribute) + 1)}
    )
    |> check_version(attribute, current, nil)
  end

  defp atomic_lock(changeset, attribute, current, condition) do
    changeset
    |> Ash.Changeset.atomic_update(
      attribute,
      {:atomic,
       Ash.Expr.expr(
         if ^condition do
           ^Ash.Expr.ref(attribute) + 1
         else
           ^Ash.Expr.ref(attribute)
         end
       )}
    )
    |> check_version(attribute, current, condition)
  end

  defp check_version(changeset, _attribute, nil, _condition), do: changeset

  defp check_version(changeset, attribute, current, nil) do
    Ash.Changeset.filter(changeset, Ash.Expr.expr(^Ash.Expr.ref(attribute) == ^current))
  end

  defp check_version(changeset, attribute, current, condition) do
    Ash.Changeset.filter(
      changeset,
      Ash.Expr.expr(not (^condition) or ^Ash.Expr.ref(attribute) == ^current)
    )
  end

  # See `AshQuick.Bookkeeping.Meaningful.condition/2`; a destroy is always
  # meaningful.
  defp changed_condition(%{action_type: :destroy}, _attribute), do: true

  defp changed_condition(changeset, attribute), do: Meaningful.condition(changeset, [attribute])
end
