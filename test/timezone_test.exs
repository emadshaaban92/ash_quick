defmodule AshQuick.TimezoneTest do
  @moduledoc """
  The zone a reader reads timestamps in is the one put on their process, and
  only ever one the time zone database can shift into.
  """
  use ExUnit.Case, async: true

  alias AshQuick.Test.Zones
  alias AshQuick.Timezone

  test "is the configured zone until one is put" do
    assert Timezone.current() == AshQuick.Config.timezone()
  end

  test "is the zone put on the process" do
    assert Timezone.put("Etc/UTC") == "Etc/UTC"
    assert Timezone.current() == "Etc/UTC"
  end

  # Elixir's own database knows UTC alone, so a host with no other reads a
  # browser's zone as none rather than failing to shift into it.
  test "a zone the database does not know clears it" do
    Timezone.put("Etc/UTC")

    assert Timezone.put("Asia/Tokyo") == nil
    assert Timezone.current() == AshQuick.Config.timezone()

    assert Timezone.put(nil) == nil
    assert Timezone.current() == AshQuick.Config.timezone()
  end

  test "knows a zone the database can shift into, and nothing else" do
    assert Timezone.known?("Test/Plus3", Zones)
    refute Timezone.known?("Test/Nowhere", Zones)
    refute Timezone.known?(nil, Zones)
    refute Timezone.known?(3, Zones)
  end
end
