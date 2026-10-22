defmodule AshQuick.LiveView.FilterDatetimeTest do
  @moduledoc """
  A filter's timestamp is typed in the zone the list shows it in and held as
  the UTC instant, so "after 10:00" means 10:00 where the visitor reads the
  list rather than 10:00 UTC.
  """
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.FilterDatetime

  # Two zones, enough to pin the conversion without a real time zone database:
  # one three hours ahead all year, and one that springs forward at 02:00 on
  # 2026-03-29 and falls back at 03:00 on 2026-10-25.
  defmodule Zones do
    @behaviour Calendar.TimeZoneDatabase

    @plus3 %{utc_offset: 3 * 3600, std_offset: 0, zone_abbr: "+03"}
    @winter %{utc_offset: 3600, std_offset: 0, zone_abbr: "W"}
    @summer %{utc_offset: 3600, std_offset: 3600, zone_abbr: "S"}

    @spring ~N[2026-03-29 02:00:00]
    @fall ~N[2026-10-25 03:00:00]

    @impl true
    def time_zone_period_from_utc_iso_days(_iso_days, "Test/Plus3"), do: {:ok, @plus3}

    def time_zone_period_from_utc_iso_days(iso_days, "Test/Shifting") do
      {year, month, day, hour, minute, second, _} =
        Calendar.ISO.naive_datetime_from_iso_days(iso_days)

      utc = NaiveDateTime.new!(year, month, day, hour, minute, second)

      if NaiveDateTime.compare(utc, ~N[2026-03-29 01:00:00]) != :lt and
           NaiveDateTime.compare(utc, ~N[2026-10-25 01:00:00]) == :lt,
         do: {:ok, @summer},
         else: {:ok, @winter}
    end

    def time_zone_period_from_utc_iso_days(_iso_days, _zone), do: {:error, :time_zone_not_found}

    @impl true
    def time_zone_periods_from_wall_datetime(_naive, "Test/Plus3"), do: {:ok, @plus3}

    def time_zone_periods_from_wall_datetime(naive, "Test/Shifting") do
      cond do
        between?(naive, @spring, ~N[2026-03-29 03:00:00]) ->
          {:gap, {@winter, @spring}, {@summer, ~N[2026-03-29 03:00:00]}}

        between?(naive, ~N[2026-10-25 02:00:00], @fall) ->
          {:ambiguous, @summer, @winter}

        between?(naive, ~N[2026-03-29 03:00:00], ~N[2026-10-25 02:00:00]) ->
          {:ok, @summer}

        true ->
          {:ok, @winter}
      end
    end

    def time_zone_periods_from_wall_datetime(_naive, _zone), do: {:error, :time_zone_not_found}

    defp between?(naive, from, to),
      do: NaiveDateTime.compare(naive, from) != :lt and NaiveDateTime.compare(naive, to) == :lt
  end

  describe "to_utc/3" do
    test "reads a browser's value, which has no seconds, in the list's zone" do
      assert FilterDatetime.to_utc("2026-10-22T10:00", "Test/Plus3", Zones) ==
               "2026-10-22T07:00:00Z"

      assert FilterDatetime.to_utc("2026-10-22T10:00:30", "Test/Plus3", Zones) ==
               "2026-10-22T07:00:30Z"
    end

    test "is the value as typed in UTC" do
      assert FilterDatetime.to_utc("2026-10-22T10:00", "Etc/UTC") == "2026-10-22T10:00:00Z"
    end

    test "reads a skipped wall time as the first instant after the gap" do
      assert FilterDatetime.to_utc("2026-03-29T02:30", "Test/Shifting", Zones) ==
               "2026-03-29T01:00:00Z"
    end

    test "reads a repeated wall time as the earlier instant" do
      assert FilterDatetime.to_utc("2026-10-25T02:30", "Test/Shifting", Zones) ==
               "2026-10-25T00:30:00Z"
    end

    test "leaves what will not parse as it was typed, for the read to refuse" do
      for value <- ["", "tomorrow", "2026-13-01T10:00"] do
        assert FilterDatetime.to_utc(value, "Test/Plus3", Zones) == value
      end

      assert FilterDatetime.to_utc(nil, "Test/Plus3", Zones) == nil

      assert FilterDatetime.to_utc("2026-10-22T10:00", "Test/Nowhere", Zones) ==
               "2026-10-22T10:00"
    end
  end

  describe "to_local/3" do
    test "shows a held instant in the list's zone, to the minute" do
      assert FilterDatetime.to_local("2026-10-22T07:00:00Z", "Test/Plus3", Zones) ==
               "2026-10-22T10:00"
    end

    test "keeps seconds the instant has" do
      assert FilterDatetime.to_local("2026-10-22T07:00:30Z", "Test/Plus3", Zones) ==
               "2026-10-22T10:00:30"
    end

    test "reads a value with no zone, from a URL written before, as UTC" do
      assert FilterDatetime.to_local("2026-10-22T07:00", "Test/Plus3", Zones) ==
               "2026-10-22T10:00"
    end

    test "is the inverse of to_utc/3" do
      for typed <- ["2026-01-05T09:15", "2026-07-05T23:59", "2026-10-22T10:00:30"] do
        held = FilterDatetime.to_utc(typed, "Test/Shifting", Zones)
        assert FilterDatetime.to_local(held, "Test/Shifting", Zones) == typed
      end
    end

    test "shows what will not parse as it was typed" do
      assert FilterDatetime.to_local("tomorrow", "Test/Plus3", Zones) == "tomorrow"
      assert FilterDatetime.to_local(nil, "Test/Plus3", Zones) == nil
    end
  end
end
