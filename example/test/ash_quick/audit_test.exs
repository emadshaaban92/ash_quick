defmodule AshQuick.AuditTest do
  @moduledoc """
  The audit row is written inside the transaction of the write it describes.

  That is the claim only a transactional data layer can carry: a store that
  refuses the entry has to take the record back with it, and the caller is left
  with neither. The library's own suite runs on ETS, which has no transactions
  and so cannot show it.
  """
  # `async: false`: the store is swapped through the application environment,
  # which every other test in the suite reads.
  use Example.DataCase, async: false

  require Ash.Query

  alias Example.Catalog.Brand

  setup do
    # The store is read per write rather than baked into the resource, so
    # swapping the application environment is enough to point it at one that
    # refuses.
    previous = Application.get_env(:ash_quick, :audit_resource)
    Application.put_env(:ash_quick, :audit_resource, AshQuick.AuditTest.RefusingStore)
    on_exit(fn -> Application.put_env(:ash_quick, :audit_resource, previous) end)

    :ok
  end

  test "a store that refuses the batch fails the write, naming the resource and itself",
       %{admin: admin} do
    code = unique("B")

    # Ash wraps what a hook raises, which is what carries the reason out to the
    # caller — the entry could not be written, so neither could the brand.
    error =
      assert_raise Ash.Error.Unknown, fn ->
        Brand.create!(%{code: code, name: unique("Brand ")}, actor: admin, authorize?: false)
      end

    message = Exception.message(error)

    # Both ends of the write, so the report names what was being audited as well
    # as what would not take the entry.
    assert message =~ inspect(Brand)
    assert message =~ inspect(AshQuick.AuditTest.RefusingStore)

    # The store's own reason, rather than a MatchError on the bulk result.
    assert message =~ "audit store unreachable"

    # The brand was inserted and then rolled back with the refused entry, so
    # nothing is there — the property a non-transactional store cannot show.
    assert [] = Brand |> Ash.Query.filter(code == ^code) |> Ash.read!(authorize?: false)
  end
end
