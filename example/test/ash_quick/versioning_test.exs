defmodule AshQuick.VersioningTest do
  @moduledoc """
  The optimistic lock AshQuick wires onto every versioned resource.

  This is the test that most needs a host. The lock decides whether to filter
  and bump `:version` in a `before_action`, against the final changeset — so
  what it proves is that a filter set there is honored by **AshPostgres**, and
  an in-memory data layer cannot stand in for that.

  Driven against `Example.Catalog.Brand`, which carries nothing but the
  extension's defaults: a stale write here fails because of versioning and not
  because of anything the resource says. Its actions are Ash's defaults, which
  run in memory; `Example.Test.AtomicBrand` writes the same rows through named
  actions that run atomically, where the lock is an expression PostgreSQL
  evaluates inside the `UPDATE`.
  """
  use Example.DataCase, async: true

  require Ash.Query

  alias Example.Accounts.AuditLog
  alias Example.Catalog.Brand
  alias Example.Test.AtomicBrand

  describe "optimistic lock" do
    test "rejects a stale write (a filter set in a before_action is honored)", %{admin: admin} do
      brand = brand(actor: admin)
      assert brand.version == 1

      # Two in-memory copies at version 1.
      copy_a = brand
      copy_b = brand

      updated_a =
        Brand.update!(copy_a, %{name: unique("First write ")}, actor: admin, authorize?: false)

      assert updated_a.version == 2

      assert_raise Ash.Error.Invalid, ~r/stale record/i, fn ->
        Brand.update!(copy_b, %{name: unique("Second write ")}, actor: admin, authorize?: false)
      end
    end

    test "locks + bumps when the only change is injected by a before_action", %{admin: admin} do
      brand = brand(actor: admin)
      assert brand.version == 1

      # No accepted params, so at the change phase the changeset is empty and a
      # change-phase guard would skip the lock entirely. A prepended
      # `before_action` injects the real change — mirroring a resource-registered
      # change that mutates in its own `before_action` — and runs before the
      # lock's appended hook, so the lock must still see it.
      injected_name = unique("Injected by before_action ")

      injected =
        brand
        |> Ash.Changeset.for_update(:update, %{}, actor: admin, authorize?: false)
        |> Ash.Changeset.before_action(
          &Ash.Changeset.force_change_attribute(&1, :name, injected_name),
          prepend?: true
        )
        |> Ash.update!()

      assert injected.name == injected_name
      assert injected.version == 2
    end

    test "a genuine no-op neither bumps the version nor rejects", %{admin: admin} do
      brand = brand(actor: admin)
      assert brand.version == 1

      # Re-submitting the same name changes nothing meaningful.
      result = Brand.update!(brand, %{name: brand.name}, actor: admin, authorize?: false)

      assert result.version == 1
    end

    test "a bookkeeping-only difference is not a change either", %{admin: admin, editor: editor} do
      brand = brand(actor: admin)

      # A different actor stamps a different `updated_by`, and that is the whole
      # of the difference — `AshQuick.Config.versioning_ignored_attributes/1`
      # reads the resource's bookkeeping declaration and leaves those out.
      result = Brand.update!(brand, %{name: brand.name}, actor: editor, authorize?: false)

      assert result.version == 1
    end

    test "rejects a stale destroy", %{admin: admin} do
      brand = brand(actor: admin)
      stale = brand

      bumped = Brand.update!(brand, %{name: unique("Moved on ")}, actor: admin, authorize?: false)
      assert bumped.version == 2

      # A destroy changeset changes no attribute, so a lock that only looks at
      # what changed would let this through and delete the row somebody else
      # has since written to. Destroys are locked unconditionally.
      assert {:error, %Ash.Error.Invalid{} = error} =
               Ash.destroy(stale, actor: admin, authorize?: false)

      assert Enum.any?(error.errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
      assert {:ok, %Brand{version: 2}} = Ash.get(Brand, brand.id, actor: admin, authorize?: false)
    end

    test "destroys the record when the copy is current", %{admin: admin} do
      brand = brand(actor: admin)

      assert :ok = Ash.destroy(brand, actor: admin, authorize?: false)
      assert {:error, _} = Ash.get(Brand, brand.id, actor: admin, authorize?: false)
    end
  end

  describe "on the atomic path" do
    setup %{admin: admin} do
      brand = brand(actor: admin)
      %{brand: Ash.get!(AtomicBrand, brand.id)}
    end

    defp rename(record, input, actor) do
      record
      |> Ash.Changeset.for_update(:rename, input, actor: actor)
      |> Ash.update()
    end

    defp stale?(%{errors: errors}),
      do: Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

    defp stale?(errors) when is_list(errors), do: Enum.any?(errors, &stale?/1)
    defp stale?(%Ash.Error.Changes.StaleRecord{}), do: true
    defp stale?(_), do: false

    defp row(record), do: Ash.get!(AtomicBrand, record.id)

    test "the actions keep require_atomic?, so a write that lands ran atomically" do
      for name <- [:rename, :shout, :remove] do
        assert Ash.Resource.Info.action(AtomicBrand, name).require_atomic?
      end
    end

    test "bumps the version", %{brand: brand, admin: admin} do
      assert {:ok, %{version: 2}} = rename(brand, %{name: unique("Renamed ")}, admin)
    end

    test "refuses a stale copy, and the row keeps the other write", %{brand: brand, admin: admin} do
      first = unique("First ")
      {:ok, _} = rename(brand, %{name: first}, admin)

      assert {:error, error} = rename(brand, %{name: unique("Second ")}, admin)
      assert stale?(error)
      assert %{name: ^first, version: 2} = row(brand)
    end

    test "re-submitting what the row holds neither bumps nor refuses", %{
      brand: brand,
      admin: admin
    } do
      assert {:ok, %{version: 1}} = rename(brand, %{code: brand.code, name: brand.name}, admin)
      assert %{version: 1} = row(brand)
    end

    test "a bookkeeping-only difference is not a change", %{
      brand: brand,
      admin: admin,
      editor: editor
    } do
      # The editor stamps a different `updated_by`, and that is all that moves.
      assert {:ok, %{version: 1}} = rename(brand, %{name: brand.name}, editor)
      assert %{version: 1} = row(brand)
      assert {:ok, %{version: 2}} = rename(brand, %{name: unique("By admin ")}, admin)
    end

    test "a value unchanged from the copy but not from the row is locked", %{
      brand: brand,
      admin: admin
    } do
      theirs = unique("Theirs ")
      {:ok, _} = rename(brand, %{name: theirs}, admin)

      # The atomic path writes every accepted input, so this would put the old
      # name back over theirs.
      assert {:error, error} = rename(brand, %{name: brand.name}, admin)
      assert stale?(error)
      assert %{name: ^theirs} = row(brand)
    end

    test "an expression PostgreSQL works out is locked", %{brand: brand, admin: admin} do
      shout = fn record ->
        record |> Ash.Changeset.for_update(:shout, %{}, actor: admin) |> Ash.update()
      end

      assert {:ok, %{version: 2} = shouted} = shout.(brand)
      assert shouted.name == brand.name <> "!"

      assert {:error, error} = shout.(brand)
      assert stale?(error)
    end

    test "a read-only field is dropped on this path too", %{brand: brand, editor: editor} do
      name = unique("Editor's ")

      assert {:ok, %{code: code, name: ^name}} =
               rename(brand, %{code: unique("FORGED"), name: name}, editor)

      assert code == brand.code
    end

    test "the audit entry records the bump", %{brand: brand, admin: admin} do
      name = unique("Audited ")
      {:ok, _} = rename(brand, %{name: name}, admin)

      assert %{changes: %{"version" => %{"from" => 1, "to" => 2}, "name" => %{"to" => ^name}}} =
               AuditLog
               |> Ash.Query.filter(resource_id == ^brand.id and action_name == :rename)
               |> Ash.read_one!(authorize?: false)
    end

    # Three rows: one loaded and current, one loaded and since moved on, and
    # one named by id only, also moved on.
    defp update_many_rows(admin) do
      fresh = Ash.get!(AtomicBrand, brand(actor: admin).id)
      stale = Ash.get!(AtomicBrand, brand(actor: admin).id)
      {:ok, _} = rename(stale, %{name: unique("Moved on ")}, admin)
      by_id = brand(actor: admin)
      {:ok, _} = rename(Ash.get!(AtomicBrand, by_id.id), %{name: unique("Moved on ")}, admin)

      inputs = [
        {fresh, %{name: unique("Many ")}},
        {stale, %{name: unique("Many ")}},
        {by_id.id, %{name: unique("Many ")}}
      ]

      {inputs, fresh, stale, by_id}
    end

    defp written(result), do: result.records |> Enum.map(&{&1.id, &1.version}) |> Enum.sort()

    # `Ash.update_many/4` writes in one `MERGE`, which needs the PostgreSQL 17
    # that `Example.Repo` declares.
    test "update_many's MERGE locks each loaded record and bumps each identifier", %{
      admin: admin
    } do
      {inputs, fresh, stale, by_id} = update_many_rows(admin)

      result =
        Ash.update_many(inputs, AtomicBrand, :rename,
          actor: admin,
          return_records?: true,
          return_errors?: true
        )

      assert written(result) == Enum.sort([{fresh.id, 2}, {by_id.id, 3}])
      assert stale?(result.errors)
      assert %{version: 2} = row(stale)
    end

    # Every row's `after_batch` hook builds its own audit entry, which Ash got
    # right only from 3.37.3: before it, each row was handed the same
    # changeset, so the entries named one row's names for every row.
    test "update_many writes each row's own audit entry", %{admin: admin} do
      first = Ash.get!(AtomicBrand, brand(actor: admin).id)
      second = Ash.get!(AtomicBrand, brand(actor: admin).id)
      first_name = unique("Many ")
      second_name = unique("Many ")

      result =
        Ash.update_many(
          [{first, %{name: first_name}}, {second, %{name: second_name}}],
          AtomicBrand,
          :rename,
          actor: admin,
          return_errors?: true
        )

      assert result.status == :success

      for {brand, name} <- [{first, first_name}, {second, second_name}] do
        from = brand.name

        assert %{changes: %{"name" => %{"from" => ^from, "to" => ^name}}} =
                 AuditLog
                 |> Ash.Query.filter(resource_id == ^brand.id and action_name == :rename)
                 |> Ash.read_one!(authorize?: false)
      end
    end

    test "a bulk write by query declines the atomic strategy and streams, locked", %{
      brand: brand,
      admin: admin
    } do
      query = Ash.Query.filter(AtomicBrand, id == ^brand.id)

      assert %Ash.BulkResult{status: :error} =
               Ash.bulk_update(query, :rename, %{name: unique("Bulk ")},
                 actor: admin,
                 strategy: :atomic
               )

      assert %Ash.BulkResult{status: :success, records: [%{version: 2}]} =
               Ash.bulk_update(query, :rename, %{name: unique("Bulk ")},
                 actor: admin,
                 strategy: [:atomic, :stream],
                 return_records?: true
               )
    end

    test "a stale destroy is still refused", %{brand: brand, admin: admin} do
      {:ok, _} = rename(brand, %{name: unique("Moved on ")}, admin)

      assert {:error, error} = Ash.destroy(brand, action: :remove, actor: admin)
      assert stale?(error)
      assert :ok = Ash.destroy(row(brand), action: :remove, actor: admin)
    end

    test "a destroy of a record nobody loaded goes through", %{brand: brand, admin: admin} do
      {:ok, _} = rename(brand, %{name: unique("Moved on ")}, admin)

      assert :ok = Ash.destroy(%AtomicBrand{id: brand.id}, action: :remove, actor: admin)
      assert {:error, _} = Ash.get(AtomicBrand, brand.id)
    end

    test "a built record given a stale version of its own is refused", %{
      brand: brand,
      admin: admin
    } do
      {:ok, moved} = rename(brand, %{name: unique("Moved on ")}, admin)
      {:ok, _} = rename(moved, %{name: unique("Again ")}, admin)

      # An API that takes the version the client last saw.
      held = %AtomicBrand{id: brand.id, version: 2}

      assert {:error, error} = rename(held, %{name: unique("From version 2 ")}, admin)
      assert stale?(error)

      assert {:error, error} = Ash.destroy(held, action: :remove, actor: admin)
      assert stale?(error)
      assert %{version: 3} = row(brand)
    end

    test "a built record given the first version is checked too", %{brand: brand, admin: admin} do
      {:ok, _} = rename(brand, %{name: unique("Moved on ")}, admin)

      # The client loaded the row at version 1, before the write above.
      held = %AtomicBrand{id: brand.id, version: 1}

      assert {:error, error} = rename(held, %{name: unique("From version 1 ")}, admin)
      assert stale?(error)

      assert {:error, error} = Ash.destroy(held, action: :remove, actor: admin)
      assert stale?(error)
      assert %{version: 2} = row(brand)
    end

    defp upsert(action \\ :upsert, input, actor) do
      AtomicBrand
      |> Ash.Changeset.for_create(action, input, actor: actor)
      |> Ash.create()
    end

    test "an upsert that writes over a row bumps its version", %{brand: brand, admin: admin} do
      name = unique("Imported ")

      assert {:ok, %{name: ^name, version: 2}} =
               upsert(%{code: brand.code, name: name}, admin)

      assert {:error, error} = rename(brand, %{name: unique("From the old copy ")}, admin)
      assert stale?(error)
      assert %{name: ^name, version: 2} = row(brand)
    end

    test "an upsert that writes what the row holds leaves the version alone", %{
      brand: brand,
      admin: admin
    } do
      assert {:ok, %{version: 1}} = upsert(%{code: brand.code, name: brand.name}, admin)
      assert {:ok, %{version: 2}} = rename(brand, %{name: unique("Still current ")}, admin)
    end

    test "an upsert that replaces every field bumps the version rather than resetting it", %{
      brand: brand,
      admin: admin
    } do
      {:ok, moved} = rename(brand, %{name: unique("Second ")}, admin)
      {:ok, _} = rename(moved, %{name: unique("Third ")}, admin)

      assert {:ok, %{version: 4} = upserted} =
               upsert(:upsert_all, %{code: brand.code, name: unique("Imported ")}, admin)

      # A copy from before any of it must not come back to life. `:replace_all`
      # writes the key too, so the row now carries the upsert's id.
      old_copy = %AtomicBrand{id: upserted.id, version: 1}
      assert {:error, error} = rename(old_copy, %{name: unique("Old ")}, admin)
      assert stale?(error)
    end

    test "a bulk upsert bumps each row it writes over, and only those", %{
      brand: one,
      admin: admin
    } do
      two = Ash.get!(AtomicBrand, brand(actor: admin).id)
      name = unique("Again ")

      assert %Ash.BulkResult{status: :success} =
               Ash.bulk_create(
                 [%{code: one.code, name: name}, %{code: two.code, name: two.name}],
                 AtomicBrand,
                 :upsert,
                 actor: admin,
                 return_errors?: true
               )

      assert %{name: ^name, version: 2} = row(one)
      assert %{version: 1} = row(two)
    end
  end
end
