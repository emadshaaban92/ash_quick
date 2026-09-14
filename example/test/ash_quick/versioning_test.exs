defmodule AshQuick.VersioningTest do
  @moduledoc """
  The optimistic lock AshQuick wires onto every versioned resource.

  This is the test that most needs a host. The lock decides whether to filter
  and bump `:version` in a `before_action`, against the final changeset — so
  what it proves is that a filter set there is honored by **AshPostgres**, and
  an in-memory data layer cannot stand in for that.

  Driven against `Example.Catalog.Brand`, which carries nothing but the
  extension's defaults: a stale write here fails because of versioning and not
  because of anything the resource says.
  """
  use Example.DataCase, async: true

  alias Example.Catalog.Brand

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
  end
end
