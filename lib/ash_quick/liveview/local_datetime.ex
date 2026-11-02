defmodule AshQuick.LiveView.LocalDatetime do
  @moduledoc false

  # A `datetime-local` input names no zone, and Ash would cast its bare value
  # as UTC. Pages show timestamps in the reader's zone
  # (`AshQuick.Timezone.current/0`), so that is the zone a reader types one
  # in. A filter and a form therefore hold the UTC instant, with its `Z`, and
  # the input shows it back in the reader's zone.
  #
  # A value with no zone that reaches `to_local/3` was read as UTC, so it is
  # still read that way: a filter in a URL written before filters held
  # instants. Anything that will not parse is left as it was typed, for the
  # read or the action to refuse.

  # The types a form and a filter draw a `datetime-local` input for, and so
  # the ones whose posted value is read in the reader's zone. The one list:
  # an input drawn for a type this misses would be saved as UTC.
  @instant_types [Ash.Type.DateTime, Ash.Type.UtcDatetime, Ash.Type.UtcDatetimeUsec]

  @doc """
  Whether a field of `type` is an instant, typed into a `datetime-local` input.
  """
  defguard is_instant_type(type) when type in @instant_types

  @doc """
  `params` posted to an `AshPhoenix.Form`, with every instant typed into the
  form or one of its sub-forms read in `timezone` and held as UTC.

  Each (sub-)form is found in the params by its name, and its own resource and
  action say which of its inputs are instants. A sub-form the page drew is in
  the form already, so every input a person typed into is covered; params for
  one the form does not hold are left alone. Converting is idempotent, so
  params already converted pass through unchanged.

  The input shows a held value to the second, so a value posted back as the
  input showed the record's own is that stored instant, microseconds and all:
  an untouched field is no change.
  """
  def form_params_to_utc(
        params,
        form,
        timezone,
        database \\ Calendar.get_time_zone_database()
      )

  def form_params_to_utc(params, %AshPhoenix.Form{} = form, timezone, database)
      when is_map(params) do
    root = name_path(form.name)

    form
    |> with_sub_forms()
    |> Enum.reduce(params, fn sub_form, acc ->
      case instant_inputs(sub_form) do
        [] ->
          acc

        names ->
          path = Enum.drop(name_path(sub_form.name), length(root))
          update_at(acc, path, &inputs_to_utc(&1, sub_form, names, timezone, database))
      end
    end)
  end

  def form_params_to_utc(params, _form, _timezone, _database), do: params

  defp with_sub_forms(form) do
    [
      form
      | Enum.flat_map(form.forms, fn {_key, sub_forms} ->
          sub_forms |> List.wrap() |> Enum.flat_map(&with_sub_forms/1)
        end)
    ]
  end

  # `form[items][0]` is at `["items", "0"]` under the root's `form`.
  defp name_path(name) when is_binary(name),
    do: ~r/[^\[\]]+/ |> Regex.scan(name) |> List.flatten()

  defp name_path(_name), do: []

  defp update_at(params, [], fun) when is_map(params), do: fun.(params)

  defp update_at(params, [key | rest], fun) when is_map(params) do
    case params do
      %{^key => nested} when is_map(nested) -> Map.put(params, key, update_at(nested, rest, fun))
      _elsewhere -> params
    end
  end

  defp update_at(params, _path, _fun), do: params

  defp inputs_to_utc(params, form, names, timezone, database) do
    Enum.reduce(names, params, fn name, acc ->
      case acc do
        %{^name => value} -> Map.put(acc, name, posted_utc(value, form, name, timezone, database))
        _absent -> acc
      end
    end)
  end

  defp posted_utc(value, form, name, timezone, database) do
    case stored(form, name) do
      %DateTime{} = stored ->
        if value == to_local(stored, timezone, database),
          do: DateTime.to_iso8601(stored),
          else: to_utc(value, timezone, database)

      _none ->
        to_utc(value, timezone, database)
    end
  end

  # The record's own value of an attribute, which an argument, and a form
  # with no record, has none of. `name` is one of the action's inputs, so its
  # atom exists.
  defp stored(%AshPhoenix.Form{data: %{} = data}, name),
    do: Map.get(data, String.to_existing_atom(name))

  defp stored(_form, _name), do: nil

  # The accepted attributes and arguments of the form's action a form draws a
  # `datetime-local` input for.
  defp instant_inputs(%AshPhoenix.Form{resource: resource, action: action}) do
    case resource && Ash.Resource.Info.action(resource, action) do
      nil ->
        []

      action ->
        accepted =
          for name <- Map.get(action, :accept) || [],
              %{type: type} <- [Ash.Resource.Info.attribute(resource, name)],
              is_instant_type(type),
              do: to_string(name)

        arguments =
          for %{type: type, name: name} <- action.arguments,
              is_instant_type(type),
              do: to_string(name)

        accepted ++ arguments
    end
  end

  @doc """
  The UTC instant a `datetime-local` value means in `timezone`, as ISO 8601.

  A wall time the zone skips (a spring-forward gap) is read as the first
  instant after it; one the zone repeats, as the earlier of the two. A value
  that already names its offset is that instant, so converting twice changes
  nothing.
  """
  def to_utc(value, timezone, database \\ Calendar.get_time_zone_database())

  def to_utc(value, timezone, database) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        utc_iso8601(datetime)

      {:error, _} ->
        with {:ok, naive} <- parse_naive(value),
             {:ok, datetime} <- from_naive(naive, timezone, database) do
          utc_iso8601(datetime)
        else
          _ -> value
        end
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
