defmodule AshQuick.Storage.Sweeper do
  @moduledoc """
  Deletes exports nobody can download any more.

  An export is a whole list written to storage for one download, and its link
  lasts an hour. Left alone the files stay for ever, each a copy of the data
  outside the policies that guard the records. So once an hour this asks the
  configured storage to delete what is under `exports/` and older than
  `AshQuick.Config.export_retention/0`, a day by default, through
  `AshQuick.Storage.sweep_exports/1`.

  It runs under `AshQuick` in the host's supervision tree, and on every node:
  deleting a file that is already gone is not an error.

  Only a storage that implements `c:AshQuick.Storage.delete_expired/3` is
  swept. `AshQuick.Storage.Local` does. A bucket is cleared by a lifecycle
  rule on its `exports/` prefix instead, which the bucket runs itself.

  A sweep that fails is logged and tried again an hour later; it never takes
  the process down.
  """

  use GenServer

  require Logger

  @first_sweep :timer.minutes(1)
  @interval :timer.hours(1)

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    Process.send_after(self(), :sweep, @first_sweep)
    {:ok, nil}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    sweep()
    Process.send_after(self(), :sweep, @interval)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc "One sweep, now. Answers what `AshQuick.Storage.sweep_exports/1` did."
  def sweep do
    case AshQuick.Storage.sweep_exports() do
      {:ok, _deleted} = swept ->
        swept

      {:error, reason} = error ->
        Logger.warning("AshQuick could not sweep expired exports: #{inspect(reason)}")
        error
    end
  rescue
    exception ->
      Logger.warning("AshQuick could not sweep expired exports: " <> Exception.message(exception))

      {:error, exception}
  end
end
