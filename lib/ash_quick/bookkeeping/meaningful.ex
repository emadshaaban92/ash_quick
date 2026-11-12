defmodule AshQuick.Bookkeeping.Meaningful do
  @moduledoc false
  # Whether an update changes anything besides bookkeeping: an attribute or
  # relationship other than the ones `AshQuick.Config.versioning_ignored_attributes/1`
  # and `versioning_ignored_relationships/1` name, and other than the extra
  # attributes a caller passes (the lock's own counter).
  #
  # One answer for the two things that must agree on it. `AshQuick.Versioning.Lock`
  # bumps `version` only for a meaningful write, and `AshQuick.Bookkeeping.StampWriter`
  # stamps `updated_by` only for one; with the stamp gone, Ash's own
  # `update_timestamp` leaves `updated_at` alone on the same writes. A write that
  # changes nothing has nothing to attribute, so all three move together or not
  # at all.
  #
  # In memory the answer is a boolean over the changeset, where a value equal to
  # what the record holds is already not a change — Ash drops it. On the atomic
  # path Ash writes every accepted input as an atomic, unchanged ones included,
  # so the answer is an expression the data layer evaluates against the row.

  require Ash.Expr

  @doc false
  # The in-memory answer, for a changeset whose every change has run.
  #
  # An atomic counts too: `Ash.Changeset.atomic_update/3` files its value under
  # `changeset.atomics` on this path as well, and Ash writes it. Memory cannot
  # compare an expression with the row, so any atomic not ignored is taken as
  # a change — the side that stamps and locks rather than the one that lets a
  # real write through unattributed and unlocked.
  def meaningful?(changeset, also_ignore \\ []) do
    {attributes, relationships} = changes(changeset, also_ignore)
    atomics = Keyword.drop(changeset.atomics, ignored_attributes(changeset, also_ignore))

    not (attributes == %{} and relationships == %{} and atomics == [])
  end

  @doc false
  # The atomic answer: `nil` when the write cannot be meaningful whatever the
  # row holds, `true` when it is meaningful whatever the row holds, and
  # otherwise an expression that is true when a value being written differs
  # from the row's.
  def condition(changeset, also_ignore \\ []) do
    {attributes, relationships} = changes(changeset, also_ignore)

    atomics = Keyword.drop(changeset.atomics, ignored_attributes(changeset, also_ignore))

    if relationships == %{} do
      atomics
      |> Enum.concat(attributes)
      |> Enum.map(fn {key, value} -> differs(changeset.resource, key, value) end)
      |> Enum.reduce(nil, fn
        differs, nil -> differs
        differs, condition -> Ash.Expr.expr(^condition or ^differs)
      end)
    else
      true
    end
  end

  defp changes(%{resource: resource} = changeset, also_ignore) do
    attributes = Map.drop(changeset.attributes, ignored_attributes(changeset, also_ignore))

    relationships =
      Map.drop(
        changeset.relationships,
        AshQuick.Config.versioning_ignored_relationships(resource)
      )

    {attributes, relationships}
  end

  defp ignored_attributes(changeset, also_ignore) do
    also_ignore ++ AshQuick.Config.versioning_ignored_attributes(changeset.resource)
  end

  # How Ash compares a written value with the row when it decides whether an
  # `update_default` applies — `atomic_default_condition` in `Ash.Changeset` —
  # but with a write from or to `nil` counted as a change wherever the data
  # layer cannot say `is_distinct_from`: missing one is an under-lock, where
  # Ash only misses a timestamp.
  defp differs(resource, key, value) do
    ref = Ash.Expr.ref(key)
    distinct = Ash.Expr.expr(is_distinct_from(^value, ^ref))

    cond do
      not Ash.Expr.can_return_nil?(value) and
          not Ash.Resource.Info.attribute(resource, key).allow_nil? ->
        Ash.Expr.expr(^value != ^ref)

      Ash.DataLayer.data_layer_can?(resource, {:filter_expr, distinct}) ->
        distinct

      true ->
        nil_safe_differs(value, ref)
    end
  end

  defp nil_safe_differs(value, ref) do
    Ash.Expr.expr(
      cond do
        is_nil(^value) and is_nil(^ref) -> false
        is_nil(^value) or is_nil(^ref) -> true
        true -> ^value != ^ref
      end
    )
  end
end
