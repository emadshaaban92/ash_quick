defmodule AshQuick.Timezone do
  @moduledoc """
  The zone a reader reads timestamps in.

  Lists, details pages, filters, forms and exports show a timestamp in
  `current/0`, and read one typed into a form or a filter in it too. It is the
  reader's scope's zone (`AshQuick.Scope.timezone/1`), put on the LiveView's
  process by `AshQuick.LiveView.Timezone` and by a QuickView when it mounts,
  and `AshQuick.Config.timezone/0` without one.

  Which zone the scope names is the host's decision: a zone kept on the user,
  one for the whole organisation, or the one the reader's browser reports. The
  scope names the field (`use AshQuick.Scope, timezone: :timezone`) and the
  host's scope stage fills it.

  A zone is only ever one the time zone database knows (`known?/1`). Elixir
  ships a database that knows UTC alone, so a host showing any other zone
  configures a full one, such as `tz`'s:

      config :elixir, :time_zone_database, Tz.TimeZoneDatabase

  ## Custom form templates and widgets

  A `datetime-local` input names no zone, and a QuickView reads what it posts
  in `current/0`. So it has to show the held value in that zone too, or an
  untouched field moves by the zone's offset on every save.
  `AshQuick.Components.input/1` does that for a `type="datetime-local"` field.
  A template or form widget drawing the input any other way, such as with the
  host's own `core_components`, passes the value through `input_value/1`, and
  `step="1"` so a value with seconds stays valid:

      <.input
        field={@form[:starts_at]}
        type="datetime-local"
        value={AshQuick.Timezone.input_value(@form[:starts_at].value)}
        step="1"
      />
  """

  alias AshQuick.LiveView.LocalDatetime

  @key {__MODULE__, :current}

  @doc """
  The zone this process shows timestamps in: the one `put/1` stored, or
  `AshQuick.Config.timezone/0`.
  """
  def current, do: Process.get(@key) || AshQuick.Config.timezone()

  @doc """
  Stores `timezone` as this process's, when the time zone database knows it.

  `nil`, or a zone the database does not know, clears it, so `current/0`
  falls back to `AshQuick.Config.timezone/0` rather than failing to shift a
  timestamp into it. Returns `timezone` when stored, `nil` otherwise.
  """
  def put(timezone) do
    if known?(timezone) do
      Process.put(@key, timezone)
      timezone
    else
      Process.delete(@key)
      nil
    end
  end

  @doc """
  Whether `timezone` is a zone `database` can shift a timestamp into.
  """
  def known?(timezone, database \\ Calendar.get_time_zone_database())

  def known?(timezone, database) when is_binary(timezone) do
    match?({:ok, _}, DateTime.shift_zone(DateTime.utc_now(), timezone, database))
  end

  def known?(_timezone, _database), do: false

  @doc """
  What a `datetime-local` input shows for a form field's value: a `DateTime`,
  or an ISO 8601 string naming its offset, as the wall time in `current/0`, to
  the minute or to the second when it has seconds (`"2026-10-22T10:00"`). A
  value with no zone is read as UTC; one that will not parse, or `nil`, is
  returned as it is.
  """
  def input_value(value), do: LocalDatetime.to_local(value, current())
end
