defmodule AshQuick.Test.Zones do
  @moduledoc """
  Two zones, enough to pin a conversion without a real time zone database:
  `Test/Plus3`, three hours ahead all year, and `Test/Shifting`, which springs
  forward at 02:00 on 2026-03-29 and falls back at 03:00 on 2026-10-25.
  """
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
