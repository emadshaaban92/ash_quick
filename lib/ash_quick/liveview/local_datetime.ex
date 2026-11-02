defmodule AshQuick.LiveView.LocalDatetime do
  @moduledoc false

  # A `datetime-local` input names no zone, and Ash would cast its bare value
  # as UTC. The list shows timestamps in the reader's zone
  # (`AshQuick.Scope.timezone/1`), so that is the zone a visitor types one into
  # a filter in. The filter therefore holds the UTC instant, with its `Z`, and
  # the input shows it back in the reader's zone. A form's input names its
  # zone beside it instead; see `AshQuick.Components.zoned_datetime_input/1`.
  #
  # A value from before the filter held instants has no zone either, and was
  # read as UTC, so it is still read that way. Anything that will not parse is
  # left as it was typed: the read refuses it, as it would have before.

  @doc """
  The UTC instant a `datetime-local` value means in `timezone`, as ISO 8601.

  A wall time the zone skips (a spring-forward gap) is read as the first
  instant after it; one the zone repeats, as the earlier of the two.
  """
  def to_utc(value, timezone, database \\ Calendar.get_time_zone_database())

  def to_utc(value, timezone, database) when is_binary(value) do
    with {:ok, naive} <- parse_naive(value),
         {:ok, datetime} <- from_naive(naive, timezone, database) do
      utc_iso8601(datetime)
    else
      _ -> value
    end
  end

  def to_utc(value, _timezone, _database), do: value

  @doc """
  What a `datetime-local` input shows for a held value, a `DateTime` or an
  ISO 8601 string: the instant in `timezone`, to the minute, or to the second
  when it has seconds. An instant the zone cannot hold shows in UTC.
  """
  def to_local(value, timezone, database \\ Calendar.get_time_zone_database())

  def to_local(%DateTime{} = datetime, timezone, database) do
    case DateTime.shift_zone(datetime, timezone, database) do
      {:ok, local} -> wall_time(local)
      {:error, _} -> wall_time(datetime)
    end
  end

  def to_local(value, timezone, database) when is_binary(value) do
    case parse_instant(value) do
      {:ok, datetime} -> to_local(datetime, timezone, database)
      _unparseable -> value
    end
  end

  def to_local(value, _timezone, _database), do: value

  @doc """
  What a form posts for a held value: a `DateTime` as ISO 8601, to the
  microsecond it holds, so a field nobody touched posts back exactly what the
  record holds. Anything else, such as a value that did not cast, as it is.
  """
  def instant(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  def instant(nil), do: ""
  def instant(value) when is_binary(value), do: value
  def instant(value), do: to_string(value)

  @doc """
  The day a `date` value names in `timezone`, as the UTC instants it starts
  and the next day starts at, in ISO 8601: the range On Day keeps, from the
  first up to but not including the second. A day the zone starts in a gap
  starts at the first instant after it.
  """
  def day_range(value, timezone, database \\ Calendar.get_time_zone_database())

  def day_range(value, timezone, database) when is_binary(value) do
    with {:ok, date} <- Date.from_iso8601(value),
         {:ok, from} <- start_of_day(date, timezone, database),
         {:ok, to} <- start_of_day(Date.add(date, 1), timezone, database) do
      {:ok, utc_iso8601(from), utc_iso8601(to)}
    else
      _ -> :error
    end
  end

  def day_range(_value, _timezone, _database), do: :error

  defp start_of_day(date, timezone, database),
    do: date |> NaiveDateTime.new!(~T[00:00:00]) |> from_naive(timezone, database)

  defp utc_iso8601(datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC", Calendar.UTCOnlyTimeZoneDatabase)
    |> DateTime.to_iso8601()
  end

  defp parse_instant(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, _} ->
        with {:ok, naive} <- parse_naive(value), do: DateTime.from_naive(naive, "Etc/UTC")
    end
  end

  # Browsers send `2026-10-22T10:00`, without seconds, which ISO 8601 parsing
  # in Elixir requires.
  defp parse_naive(<<_::binary-size(16)>> = value), do: NaiveDateTime.from_iso8601(value <> ":00")
  defp parse_naive(value), do: NaiveDateTime.from_iso8601(value)

  defp from_naive(naive, timezone, database) do
    case DateTime.from_naive(naive, timezone, database) do
      {:ok, datetime} -> {:ok, datetime}
      {:ambiguous, earlier, _later} -> {:ok, earlier}
      {:gap, _before, after_gap} -> {:ok, after_gap}
      {:error, _} = error -> error
    end
  end

  defp wall_time(datetime) do
    case datetime |> DateTime.to_naive() |> NaiveDateTime.truncate(:second) do
      %NaiveDateTime{second: 0} = naive ->
        naive |> NaiveDateTime.to_iso8601() |> binary_part(0, 16)

      naive ->
        NaiveDateTime.to_iso8601(naive)
    end
  end
end
