defmodule AshQuick.LiveView.FormRecordsTest do
  @moduledoc """
  The keys a form picker holds are named in reads the lookup action allows:
  past its `max_page_size`, in several. A lookup that fails is logged, and
  offers and names nothing.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshQuick.LiveView.FormRecords
  alias Example.Test.CappedKeys

  test "names every held key, past the lookup action's max page size" do
    records =
      for n <- 1..5, do: Ash.create!(CappedKeys, %{code: "C#{n}-#{System.unique_integer()}"})

    relationship = %Ash.Resource.Relationships.BelongsTo{
      name: :capped,
      source: Example.Test.UnseenKeepers,
      destination: CappedKeys,
      destination_attribute: :id,
      filters: []
    }

    values = Enum.map(records, & &1.id)
    options = FormRecords.resolve(relationship, :id, values, nil, [])

    assert options |> Enum.map(& &1.value) |> Enum.sort() == Enum.sort(values)

    assert options |> Enum.map(& &1.label) |> Enum.sort() ==
             records |> Enum.map(& &1.code) |> Enum.sort()
  end

  test "a refused lookup offers and names nothing, and says why in the log" do
    record = Ash.create!(Example.Test.RefusedLookups, %{code: "R"})

    relationship = %Ash.Resource.Relationships.BelongsTo{
      name: :refused,
      source: Example.Test.UnseenKeepers,
      destination: Example.Test.RefusedLookups,
      destination_attribute: :id,
      filters: []
    }

    log =
      capture_log(fn ->
        assert FormRecords.search(relationship, :id, nil, nil, []) == []
        assert FormRecords.resolve(relationship, :id, [record.id], nil, []) == []
      end)

    assert log =~ "could not read Example.Test.RefusedLookups"
    assert log =~ "Example.Test.UnseenKeepers.refused"
    assert log =~ "refused on purpose"
  end
end
