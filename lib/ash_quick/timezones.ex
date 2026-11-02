defmodule AshQuick.Timezones do
  @moduledoc """
  The zones a reader may read and type timestamps in.

  `config :ash_quick, timezones:` lists them. Left out, the one zone allowed is
  `config :ash_quick, timezone:`, which fits an application whose readers all
  keep one clock: every page shows it, and a form's timestamp input
  (`AshQuick.Components.zoned_datetime_input/1`) offers no zone to pick.

      # Readers in two offices.
      config :ash_quick,
        timezone: "Europe/London",
        timezones: ["Europe/London", "Asia/Tokyo"]

      # Any zone the time zone database knows.
      config :ash_quick, timezones: :all

  A list must hold `:timezone`, the zone a reader falls back to. A scope's
  zone outside it reads as that one (`AshQuick.Scope.timezone/1`), so a page
  never shows a zone its forms will not take.

  With `:all`, the picker offers one zone for each clock the world keeps
  today, each labelled with its offset and the places that keep it
  (`(UTC+01:00) Berlin, Paris, Rome, …`), rather than the four hundred names
  of the database, most of which keep the same time as their neighbours. The
  reader's own zone is offered too when it is not one of those. Which zones
  that is depends on the server's time zone database, never the browser's, so
  every reader is offered the same.
  """

  # One zone per clock kept today: zones that agree on their offset and on
  # when they change it are one entry, under the zone the most people know
  # it by, and labelled with the places that keep it. Each must be a
  # canonical zone a browser's `Intl` knows, since the browser composes the
  # instant in it.
  @clocks [
    {"Pacific/Pago_Pago", "Pago Pago, Midway"},
    {"Pacific/Honolulu", "Honolulu"},
    {"Pacific/Marquesas", "Marquesas Islands"},
    {"America/Anchorage", "Anchorage"},
    {"America/Los_Angeles", "Los Angeles, Vancouver, Tijuana"},
    {"America/Phoenix", "Phoenix, Hermosillo"},
    {"America/Denver", "Denver, Calgary"},
    {"America/Chicago", "Chicago, Winnipeg"},
    {"America/Mexico_City", "Mexico City, Central America, Saskatchewan"},
    {"America/New_York", "New York, Toronto, Miami"},
    {"America/Havana", "Havana"},
    {"America/Bogota", "Bogotá, Lima, Quito, Cancún"},
    {"America/Halifax", "Halifax, Bermuda"},
    {"America/Caracas", "Caracas, La Paz, Manaus, Santo Domingo"},
    {"America/Santiago", "Santiago"},
    {"America/St_Johns", "St. John's"},
    {"America/Sao_Paulo", "São Paulo, Buenos Aires, Montevideo, Asunción"},
    {"America/Nuuk", "Nuuk"},
    {"America/Noronha", "Fernando de Noronha, South Georgia"},
    {"Atlantic/Azores", "Azores"},
    {"Atlantic/Cape_Verde", "Cape Verde"},
    {"Etc/UTC", "Coordinated Universal Time"},
    {"Europe/London", "London, Dublin, Lisbon"},
    {"Africa/Abidjan", "Accra, Dakar, Reykjavík"},
    {"Africa/Casablanca", "Casablanca"},
    {"Europe/Berlin", "Berlin, Paris, Madrid, Rome, Amsterdam, Warsaw"},
    {"Africa/Lagos", "Lagos, Algiers, Kinshasa, Tunis"},
    {"Europe/Athens", "Athens, Bucharest, Helsinki, Kyiv, Sofia"},
    {"Africa/Cairo", "Cairo"},
    {"Asia/Jerusalem", "Jerusalem"},
    {"Asia/Beirut", "Beirut"},
    {"Africa/Johannesburg", "Johannesburg, Maputo, Tripoli, Kaliningrad"},
    {"Europe/Moscow", "Moscow, Istanbul, Riyadh, Baghdad, Nairobi, Minsk"},
    {"Asia/Tehran", "Tehran"},
    {"Asia/Dubai", "Dubai, Baku, Tbilisi, Yerevan, Samara"},
    {"Asia/Kabul", "Kabul"},
    {"Asia/Karachi", "Karachi, Tashkent, Almaty, Yekaterinburg"},
    {"Asia/Kolkata", "Mumbai, New Delhi, Kolkata, Colombo"},
    {"Asia/Kathmandu", "Kathmandu"},
    {"Asia/Dhaka", "Dhaka, Bishkek, Omsk"},
    {"Asia/Yangon", "Yangon"},
    {"Asia/Bangkok", "Bangkok, Hanoi, Jakarta, Novosibirsk"},
    {"Asia/Shanghai", "Beijing, Hong Kong, Singapore, Manila, Taipei, Perth"},
    {"Australia/Eucla", "Eucla"},
    {"Asia/Tokyo", "Tokyo, Seoul, Yakutsk"},
    {"Australia/Darwin", "Darwin"},
    {"Australia/Adelaide", "Adelaide"},
    {"Australia/Brisbane", "Brisbane, Guam, Port Moresby, Vladivostok"},
    {"Australia/Sydney", "Sydney, Melbourne, Canberra, Hobart"},
    {"Australia/Lord_Howe", "Lord Howe Island"},
    {"Pacific/Noumea", "Nouméa, Solomon Islands, Magadan"},
    {"Pacific/Norfolk", "Norfolk Island"},
    {"Pacific/Auckland", "Auckland, Wellington"},
    {"Pacific/Fiji", "Fiji, Marshall Islands, Kamchatka"},
    {"Pacific/Chatham", "Chatham Islands"},
    {"Pacific/Tongatapu", "Nuku'alofa, Apia"},
    {"Pacific/Kiritimati", "Kiritimati"}
  ]

  @places Map.new(@clocks)

  @doc """
  The zones a reader may read timestamps in: the configured list, or `:all`.
  See `AshQuick.Config.timezones/0`.
  """
  def allowed, do: AshQuick.Config.timezones()

  @doc """
  Whether `timezone` is one a reader may read timestamps in: a zone the time
  zone database knows, and one the configuration allows.
  """
  def allowed?(timezone) do
    known?(timezone) and
      case allowed() do
        :all -> true
        zones -> timezone in zones
      end
  end

  @doc """
  Whether `timezone` is a zone the time zone database can shift a timestamp
  into. Elixir's own database knows UTC alone.
  """
  def known?(timezone, database \\ Calendar.get_time_zone_database())

  def known?(timezone, database) when is_binary(timezone),
    do: match?({:ok, _}, DateTime.shift_zone(DateTime.utc_now(), timezone, database))

  def known?(_timezone, _database), do: false

  @doc """
  The zones a picker offers a reader whose zone is `timezone`, as
  `{label, zone}`.

  A configured list is offered in its own order. `:all` offers one zone per
  clock the world keeps, those the database knows, with `timezone` among them
  when it is none of those, ordered by their offset now. A list of one means
  there is nothing to pick.
  """
  def options(timezone) do
    case allowed() do
      :all ->
        @clocks
        |> Enum.map(&elem(&1, 0))
        |> then(&if(timezone in &1, do: &1, else: [timezone | &1]))
        |> Enum.filter(&known?/1)
        |> Enum.map(&{offset_now(&1), &1})
        |> Enum.sort()
        |> Enum.map(fn {offset, zone} -> {label(zone, offset), zone} end)

      zones ->
        for zone <- zones, known?(zone), do: {label(zone), zone}
    end
  end

  @doc """
  How a picker names `timezone`: its offset now and the places that keep it,
  `(UTC+09:00) Tokyo, Seoul, Yakutsk`, or the city its name ends in.
  """
  def label(timezone), do: label(timezone, offset_now(timezone))

  defp label(timezone, offset) do
    places =
      Map.get_lazy(@places, timezone, fn ->
        timezone |> String.split("/") |> List.last() |> String.replace("_", " ")
      end)

    "(UTC#{format_offset(offset)}) #{places}"
  end

  defp offset_now(timezone) do
    case DateTime.shift_zone(DateTime.utc_now(), timezone) do
      {:ok, now} -> now.utc_offset + now.std_offset
      {:error, _} -> 0
    end
  end

  defp format_offset(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    minutes = div(abs(seconds), 60)
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")
    "#{sign}#{pad.(div(minutes, 60))}:#{pad.(rem(minutes, 60))}"
  end
end
