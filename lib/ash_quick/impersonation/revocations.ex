defmodule AshQuick.Impersonation.Revocations do
  @moduledoc """
  The impersonations that have been ended from outside their tab, remembered
  until their tokens would have expired anyway.

  An impersonation token is stateless: it is signed, and resolving it checks
  the signature, who minted it and its age. Ending one from the console
  (`AshQuick.BrowserSessionPresence.revoke/1`) therefore cannot rely on the tab
  dropping its token, because a client that ignores the request keeps a token
  that still resolves. This is what makes the end stick: the impersonation's id
  is recorded here, and `AshQuick.Impersonation.Token.resolve/2` refuses any
  token that names a recorded one.

  An entry is kept only until the token naming it reaches
  `AshQuick.Config.impersonation_max_age/0`, since past that the token is
  refused for its age alone, so the table holds no more than the
  impersonations ended within the last max age.

  ## Across a cluster

  Every node keeps its own table, in ETS. A revocation is written to the local
  table before `revoke/2` returns, so the node that ended it refuses the token
  at once, and is broadcast on the PubSub server `AshQuick.BrowserSessionPresence`
  rides, so every other node records it too. Whenever a node connects to
  another, each hands the other what it holds, so a node that joins later, or
  rejoins after a netsplit, learns what was revoked before it was there, and a
  deploy that replaces nodes one at a time carries the table across.

  What it does not survive is every node stopping at once, or on a single
  node this process restarting: the table lives in memory. A revoked token
  whose max age has not run out resolves again after that. Lower
  `:impersonation_max_age` if that window matters.

  It runs under `AshQuick` in the host's supervision tree. With `AshQuick` left
  out of the tree nothing is revoked, because nothing can be: the console that
  revokes reads the register that runs beside this.
  """

  use GenServer

  alias AshQuick.Config

  @table __MODULE__
  @topic "ash_quick:impersonation_revocations"
  @purge_interval :timer.minutes(5)

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Records that impersonation `id`, which started at `started_at`, has ended.

  Kept until the token naming it would have expired, and copied to every node.
  """
  def revoke(id, %DateTime{} = started_at) when is_binary(id) do
    GenServer.call(__MODULE__, {:revoke, id, expires_at(started_at)})
  end

  @doc """
  Whether impersonation `id` has been revoked.

  `false` when this register is not running, which is also when nothing can
  have been revoked.
  """
  def revoked?(id) when is_binary(id) do
    case :ets.lookup(@table, id) do
      [{^id, expires_at}] -> expires_at > now()
      [] -> false
    end
  rescue
    ArgumentError -> false
  end

  def revoked?(_id), do: false

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])

    pubsub =
      Keyword.get_lazy(opts, :pubsub_server, &AshQuick.BrowserSessionPresence.pubsub_server/0)

    :ok = Phoenix.PubSub.subscribe(pubsub, @topic)
    # Nodes connect after the tree is up, and reconnect after a netsplit, so
    # the exchange happens on every connection rather than once at boot.
    :ok = :net_kernel.monitor_nodes(true)
    # Whoever is already connected answers with what they hold.
    Phoenix.PubSub.broadcast_from(pubsub, self(), @topic, {:sync, self()})
    Process.send_after(self(), :purge, @purge_interval)

    {:ok, %{pubsub: pubsub}}
  end

  @impl GenServer
  def handle_call({:revoke, id, expires_at}, _from, state) do
    record([{id, expires_at}])
    Phoenix.PubSub.broadcast_from(state.pubsub, self(), @topic, {:revoked, [{id, expires_at}]})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:revoked, entries}, state) do
    record(entries)
    {:noreply, state}
  end

  # Both ends see the connection, so each asks the other: this side learns
  # what that one holds, and that side learns ours from its own request.
  def handle_info({:nodeup, node}, state) do
    send({__MODULE__, node}, {:sync, self()})
    {:noreply, state}
  end

  def handle_info({:sync, from}, state) do
    send(from, {:revoked, :ets.tab2list(@table)})
    {:noreply, state}
  end

  def handle_info(:purge, state) do
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:"=<", :"$1", now()}], [true]}])
    Process.send_after(self(), :purge, @purge_interval)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp record(entries) do
    now = now()
    :ets.insert(@table, Enum.filter(entries, fn {_id, expires_at} -> expires_at > now end))
  end

  # A second past the token's own expiry. The token is signed a moment after
  # `started_at` and checked to the millisecond, while this keeps whole
  # seconds, so without it the entry could lapse before the token does.
  defp expires_at(started_at) do
    DateTime.to_unix(started_at) + Config.impersonation_max_age() + 1
  end

  defp now, do: System.system_time(:second)

  @doc false
  def topic, do: @topic
end
