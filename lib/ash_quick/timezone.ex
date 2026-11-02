defmodule AshQuick.Timezone do
  @moduledoc """
  The zone a reader reads timestamps in.

  Lists, details pages, filters, forms and exports show a timestamp in
  `current/0`, and read one typed into a form or a filter in it too. It is the
  reader's scope's zone (`AshQuick.Scope.timezone/1`), which a QuickView puts
  on its process when it mounts, and `AshQuick.Config.timezone/0` before then.

  A browser reports its own zone when the socket connects, and
  `AshQuick.LiveView.Mount.timezone/1` reads it back for the host's scope:

      scope =
        MyApp.Scope.new(
          actor: socket.assigns.current_user,
          ip: AshQuick.LiveView.Mount.ip(socket),
          timezone: AshQuick.LiveView.Mount.timezone(socket)
        )

  with the scope naming the field (`use AshQuick.Scope, timezone: :timezone`).
  A host that keeps a zone on the user prefers it there:
  `user.timezone || AshQuick.LiveView.Mount.timezone(socket)`.

  A zone is only ever one the time zone database knows (`known?/1`). Elixir
  ships a database that knows UTC alone, so a host showing any other zone
  configures a full one, such as `tz`'s:

      config :elixir, :time_zone_database, Tz.TimeZoneDatabase

  A page of the host's own that formats with `AshQuick.Config` reads the same
  zone once it puts it: `AshQuick.Timezone.put(AshQuick.Scope.timezone(scope))`.
  """

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
end
