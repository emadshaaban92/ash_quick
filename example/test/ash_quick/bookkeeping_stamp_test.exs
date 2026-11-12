defmodule AshQuick.BookkeepingStampTest do
  @moduledoc """
  The `updated_by` stamp on PostgreSQL: an update stamps its actor, and moves
  `updated_at`, only when it changes something besides bookkeeping.

  The library suite drives the same rule on ETS, which evaluates atomics in
  Elixir. Here the atomic stamp is an expression PostgreSQL evaluates inside the
  `UPDATE` — `if <meaningful> do ^actor_id else updated_by_id end` — and
  whether `updated_at` stays put rests on AshPostgres rendering Ash's own
  comparison of that value with the row. `Example.Catalog.Brand` takes the
  in-memory path and `Example.Test.AtomicBrand` the atomic one, over the same
  rows.
  """
  use Example.DataCase, async: true

  alias Example.Catalog.Brand
  alias Example.Test.AtomicBrand

  defp row(record), do: Ash.get!(AtomicBrand, record.id)

  defp rename(record, input, actor) do
    record
    |> Ash.Changeset.for_update(:rename, input, actor: actor)
    |> Ash.update!()
  end

  defp assert_untouched(result, brand, writer) do
    assert result.updated_by_id == writer.id
    assert result.updated_at == brand.updated_at
    assert result.version == brand.version
  end

  defp assert_stamped(result, brand, writer) do
    assert result.updated_by_id == writer.id
    assert DateTime.after?(result.updated_at, brand.updated_at)
    assert result.version == brand.version + 1
  end

  describe "in memory" do
    test "a write that changes nothing stamps nobody", %{admin: admin, editor: editor} do
      brand = brand(actor: admin)

      result = Brand.update!(brand, %{name: brand.name}, actor: editor, authorize?: false)

      for result <- [result, row(brand)], do: assert_untouched(result, brand, admin)
    end

    test "a write that changes something stamps its actor", %{admin: admin, editor: editor} do
      brand = brand(actor: admin)

      result = Brand.update!(brand, %{name: unique("Renamed ")}, actor: editor, authorize?: false)

      for result <- [result, row(brand)], do: assert_stamped(result, brand, editor)
    end
  end

  describe "on the atomic path" do
    setup %{admin: admin} do
      %{brand: Ash.get!(AtomicBrand, brand(actor: admin).id)}
    end

    test "a write that changes nothing stamps nobody", %{
      brand: brand,
      admin: admin,
      editor: editor
    } do
      result = rename(brand, %{code: brand.code, name: brand.name}, editor)

      for result <- [result, row(brand)], do: assert_untouched(result, brand, admin)
    end

    test "a write that changes something stamps its actor", %{brand: brand, editor: editor} do
      result = rename(brand, %{name: unique("Renamed ")}, editor)

      for result <- [result, row(brand)], do: assert_stamped(result, brand, editor)
    end

    # One `MERGE` for every row, where Ash compares each row's value with the
    # incoming one rather than with a literal.
    test "update_many stamps only the rows it changes", %{admin: admin, editor: editor} do
      kept = Ash.get!(AtomicBrand, brand(actor: admin).id)
      renamed = Ash.get!(AtomicBrand, brand(actor: admin).id)

      result =
        Ash.update_many(
          [{kept, %{name: kept.name}}, {renamed, %{name: unique("Many ")}}],
          AtomicBrand,
          :rename,
          actor: editor,
          return_errors?: true
        )

      assert result.status == :success
      assert_untouched(row(kept), kept, admin)
      assert_stamped(row(renamed), renamed, editor)
    end
  end
end
