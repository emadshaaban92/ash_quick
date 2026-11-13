defmodule AshQuick.VersioningTest do
  @moduledoc """
  The optimistic lock on Ash's atomic path, and on the in-memory one beside it.

  `AshQuick.Test.Ledger` keeps Ash's default `require_atomic? true` on its named
  updates, so each of them either runs atomically or fails with `MustBeAtomic` —
  a passing write here is one the lock decided in `atomic/3`. ETS evaluates the
  lock's expression in memory; the example app's suite holds the same promises
  to PostgreSQL.
  """
  use ExUnit.Case, async: true

  require Ash.Query

  alias AshQuick.Test.Ledger

  defp ledger(attrs \\ %{}) do
    Ledger
    |> Ash.Changeset.for_create(:create, Map.merge(%{name: "Ledger"}, attrs))
    |> Ash.create!()
  end

  defp update(record, action, input) do
    record
    |> Ash.Changeset.for_update(action, input)
    |> Ash.update()
  end

  defp stale?(error) do
    error
    |> List.wrap()
    |> Enum.flat_map(fn
      %{errors: errors} -> errors
      error -> [error]
    end)
    |> Enum.any?(&match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  defp current(record), do: Ash.get!(Ledger, record.id)

  test "versioning leaves the actions' own require_atomic? alone" do
    for name <- [:rename, :bump, :retitle, :remove] do
      assert Ash.Resource.Info.action(Ledger, name).require_atomic?
    end

    refute Ash.Resource.Info.action(Ledger, :rename_in_memory).require_atomic?
  end

  describe "an atomic update" do
    test "bumps the version" do
      record = ledger()
      assert {:ok, %{version: 2, name: "Renamed"}} = update(record, :rename, %{name: "Renamed"})
    end

    test "refuses a stale copy, and leaves the row as the other write left it" do
      record = ledger()
      {:ok, _} = update(record, :rename, %{name: "First"})

      assert {:error, error} = update(record, :rename, %{name: "Second"})
      assert stale?(error)
      assert %{name: "First", version: 2} = current(record)
    end

    test "re-submitting what the row holds is a no-op: no bump" do
      record = ledger(%{note: "kept"})

      assert {:ok, %{version: 1}} = update(record, :rename, %{name: "Ledger", note: "kept"})
      assert %{version: 1} = current(record)
    end

    test "a no-op is judged against the row, so it holds for a stale copy too" do
      record = ledger()
      {:ok, _} = update(record, :rename, %{name: "Moved on"})

      # What the copy submits is what the row now holds: nothing would change.
      assert {:ok, _} = update(record, :rename, %{name: "Moved on"})
      assert %{version: 2} = current(record)
    end

    test "a value unchanged from the copy but not from the row is a write, and locked" do
      record = ledger()
      {:ok, _} = update(record, :rename, %{name: "Theirs"})

      # The in-memory path would drop this as unchanged. The atomic path writes
      # every accepted input, so it would put "Ledger" back over "Theirs" — the
      # lock has to catch it.
      assert {:error, error} = update(record, :rename, %{name: "Ledger"})
      assert stale?(error)
      assert %{name: "Theirs", version: 2} = current(record)
    end

    test "an expression the data layer works out is locked" do
      record = ledger()

      assert {:ok, %{count: 1, version: 2}} = update(record, :bump, %{})
      assert {:error, error} = update(record, :bump, %{})
      assert stale?(error)
    end

    test "an expression that comes to what the row holds is not a change" do
      record = ledger()

      assert {:ok, %{version: 1}} = update(record, :retitle, %{title: "Ledger"})
      assert {:ok, %{name: "Other", version: 2}} = update(record, :retitle, %{title: "Other"})
    end

    test "a change to `nil` counts" do
      record = ledger(%{note: "something"})
      assert {:ok, %{note: nil, version: 2}} = update(record, :rename, %{note: nil})
    end

    test "a record nobody loaded has no copy to be stale: bumped without the check" do
      record = ledger()
      {:ok, _} = update(record, :rename, %{name: "Moved on"})

      assert {:ok, %{version: 3}} = update(%Ledger{id: record.id}, :rename, %{name: "By id"})
      assert %{name: "By id", version: 3} = current(record)
    end

    test "a built record given a version of its own is checked like a loaded copy" do
      record = ledger()
      {:ok, _} = update(record, :rename, %{name: "Moved on"})
      {:ok, _} = update(current(record), :rename, %{name: "Again"})

      # An API that takes the version the client last saw.
      assert {:error, error} =
               update(%Ledger{id: record.id, version: 2}, :rename, %{name: "From version 2"})

      assert stale?(error)

      assert {:ok, %{version: 4}} =
               update(%Ledger{id: record.id, version: 3}, :rename, %{name: "From version 3"})
    end

    test "a built record given the first version is checked too" do
      record = ledger()
      {:ok, _} = update(record, :rename, %{name: "Moved on"})

      # The client loaded the row at version 1, before the write above.
      assert {:error, error} =
               update(%Ledger{id: record.id, version: 1}, :rename, %{name: "From version 1"})

      assert stale?(error)
      assert %{name: "Moved on", version: 2} = current(record)
    end
  end

  describe "the in-memory path beside it" do
    test "bumps, and refuses a stale copy" do
      record = ledger()

      assert {:ok, %{version: 2}} = update(record, :rename_in_memory, %{name: "First"})
      assert {:error, error} = update(record, :rename_in_memory, %{name: "Second"})
      assert stale?(error)
    end

    test "a record nobody loaded is bumped without the check" do
      record = ledger()
      {:ok, _} = update(record, :rename_in_memory, %{name: "Moved on"})

      assert {:ok, %{version: 3}} =
               update(%Ledger{id: record.id}, :rename_in_memory, %{name: "By id"})

      assert %{name: "By id", version: 3} = current(record)
    end

    test "a built record given a version of its own is checked like a loaded copy" do
      record = ledger()
      {:ok, _} = update(record, :rename, %{name: "Moved on"})
      {:ok, _} = update(current(record), :rename, %{name: "Again"})

      assert {:error, error} =
               update(%Ledger{id: record.id, version: 2}, :rename_in_memory, %{name: "Stale"})

      assert stale?(error)
    end

    test "a built record given the first version is checked too" do
      record = ledger()
      {:ok, _} = update(record, :rename, %{name: "Moved on"})

      assert {:error, error} =
               update(%Ledger{id: record.id, version: 1}, :rename_in_memory, %{name: "Stale"})

      assert stale?(error)
    end
  end

  describe "bulk writes" do
    test "by query, a meaningful write declines the atomic strategy and streams, locked" do
      record = ledger()

      query = Ash.Query.filter(Ledger, id == ^record.id)

      assert %Ash.BulkResult{status: :error, errors: [error]} =
               Ash.bulk_update(query, :rename, %{name: "Bulk"},
                 strategy: :atomic,
                 return_errors?: true
               )

      assert Exception.message(error) =~ "AshQuick versioning"

      assert %Ash.BulkResult{status: :success, records: [%{version: 2}]} =
               Ash.bulk_update(query, :rename, %{name: "Bulk"},
                 strategy: [:atomic, :stream],
                 return_records?: true,
                 return_errors?: true
               )
    end

    test "by query, a write with nothing meaningful in it stays atomic" do
      record = ledger()

      assert %Ash.BulkResult{status: :success, records: [%{version: 1}]} =
               Ledger
               |> Ash.Query.filter(id == ^record.id)
               |> Ash.bulk_update(:rename, %{},
                 strategy: :atomic,
                 return_records?: true,
                 return_errors?: true
               )
    end

    test "over loaded records, atomic batches are declined for the stream, which locks each" do
      fresh = ledger()
      stale = ledger()
      {:ok, _} = update(stale, :rename, %{name: "Moved on"})

      # A stale row matches no row on the stream, which a bulk write does not
      # count as an error: it is left out of what was written.
      assert %Ash.BulkResult{status: :success, records: [%{id: id, version: 2}]} =
               Ash.bulk_update([fresh, stale], :rename, %{name: "Bulk"},
                 strategy: [:atomic_batches, :stream],
                 return_records?: true,
                 return_errors?: true
               )

      assert id == fresh.id
      assert %{name: "Moved on", version: 2} = current(stale)
    end

    test "a destroy by query declines the atomic strategy too" do
      record = ledger()
      query = Ash.Query.filter(Ledger, id == ^record.id)

      assert %Ash.BulkResult{status: :error} =
               Ash.bulk_destroy(query, :remove, %{}, strategy: :atomic, return_errors?: true)

      assert %Ash.BulkResult{status: :success} =
               Ash.bulk_destroy(query, :remove, %{},
                 strategy: [:atomic, :stream],
                 return_errors?: true
               )
    end
  end

  describe "a destroy" do
    test "refuses a stale copy" do
      record = ledger()
      {:ok, _} = update(record, :rename, %{name: "Moved on"})

      assert {:error, error} = Ash.destroy(record, action: :remove)
      assert stale?(error)
      assert :ok = Ash.destroy(current(record), action: :remove)
    end

    test "of a record nobody loaded goes through" do
      record = ledger()
      {:ok, _} = update(record, :rename, %{name: "Moved on"})

      assert :ok = Ash.destroy(%Ledger{id: record.id}, action: :remove)
      assert {:error, _} = Ash.get(Ledger, record.id)
    end

    test "of a built record given a stale version is refused" do
      record = ledger()
      {:ok, _} = update(record, :rename, %{name: "Moved on"})
      {:ok, _} = update(current(record), :rename, %{name: "Again"})

      assert {:error, error} = Ash.destroy(%Ledger{id: record.id, version: 2}, action: :remove)
      assert stale?(error)
      assert %{version: 3} = current(record)
    end

    test "of a built record given the first version is refused once the row moved on" do
      record = ledger()
      {:ok, _} = update(record, :rename, %{name: "Moved on"})

      assert {:error, error} = Ash.destroy(%Ledger{id: record.id, version: 1}, action: :remove)
      assert stale?(error)
      assert %{version: 2} = current(record)
    end
  end

  describe "an upsert" do
    alias AshQuick.Test.ImportedLedger

    defp upsert(action \\ :upsert, input) do
      ImportedLedger
      |> Ash.Changeset.for_create(action, input)
      |> Ash.create()
    end

    defp imported(record), do: Ash.get!(ImportedLedger, record.id)

    test "that inserts starts the counter" do
      assert {:ok, %{version: 1}} = upsert(%{code: "A-1", name: "First"})
    end

    test "that writes over a row bumps its version, so a copy loaded before it is stale" do
      {:ok, record} = upsert(%{code: "A-2", name: "First"})

      assert {:ok, %{id: id, name: "Imported", version: 2}} =
               upsert(%{code: "A-2", name: "Imported"})

      assert id == record.id

      assert {:error, error} = update(record, :rename, %{name: "From the old copy"})
      assert stale?(error)
      assert %{name: "Imported", version: 2} = imported(record)
    end

    test "that writes what the row already holds leaves the version alone" do
      {:ok, record} = upsert(%{code: "A-3", name: "Same"})

      assert {:ok, %{version: 1}} = upsert(%{code: "A-3", name: "Same"})
      assert {:ok, %{version: 2}} = update(record, :rename, %{name: "Still current"})
    end

    test "that leaves out a listed field wipes it, and that counts as a change" do
      {:ok, record} = upsert(%{code: "A-5", name: "Same", note: "kept?"})

      # `upsert_fields [:name, :note]`: on ETS a field the create does not set
      # is written as `nil`.
      assert {:ok, %{note: nil, version: 2}} = upsert(%{code: "A-5", name: "Same"})

      assert {:error, error} = update(record, :rename, %{note: "From the old copy"})
      assert stale?(error)
    end

    test "that replaces every field bumps the version rather than resetting it" do
      {:ok, record} = upsert(:upsert_all, %{code: "A-4", name: "First"})
      {:ok, record} = update(record, :rename, %{name: "Second"})
      {:ok, _} = update(record, :rename, %{name: "Third"})

      assert {:ok, %{name: "Imported", version: 4} = upserted} =
               upsert(:upsert_all, %{code: "A-4", name: "Imported"})

      # A copy from before any of it must not come back to life. `:replace_all`
      # writes the key too, so the row now carries the upsert's id.
      assert {:error, error} =
               update(%ImportedLedger{id: upserted.id, version: 1}, :rename, %{name: "Old"})

      assert stale?(error)
    end

    test "in bulk bumps each row it writes over" do
      {:ok, one} = upsert(%{code: "B-1", name: "One"})
      {:ok, two} = upsert(%{code: "B-2", name: "Two"})

      assert %Ash.BulkResult{status: :success} =
               Ash.bulk_create(
                 [%{code: "B-1", name: "One again"}, %{code: "B-2", name: "Two"}],
                 ImportedLedger,
                 :upsert,
                 return_errors?: true
               )

      assert %{name: "One again", version: 2} = imported(one)
      assert %{version: 1} = imported(two)
    end
  end
end
