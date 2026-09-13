defmodule AshQuick.BrowserSessionPresence do
  @moduledoc """
  The live register of which browser tabs are signed in right now, and where
  each one is.

  A browser session lives in the tab (see `AshQuick.BrowserSession`), so no row
  anywhere says who is looking at what at this moment — the audit log only
  records who once did something. This tracks it where it actually exists: on
  the LiveView process behind the tab. A closed tab, a dropped connection or a
  lost node takes its entry with it, so there is nothing to go stale and nothing
  to clean up.

  Entries are keyed by the person at the browser, grouping all of one person's
  tabs under them, with whoever each tab is *acting as* in the metadata — which
  is the same person, unless it is standing in for somebody.

  A tab outlives its LiveView process — a refresh or a reconnect starts a new
  one — so the unit here is the tab, not the process. Every connection a tab
  makes tracks under the id the browser minted for it, and `sessions/0` reports
  the session once no matter how many of its processes are currently up. The
  path is the freshest connection's, since that is the one still saying where
  the tab has got to.

  `revoke/1` is what makes this a kill switch rather than a read-out: the only
  way to cut an impersonation off from outside the tab. Only an impersonation —
  it refuses an id that names an ordinary session, because ending somebody's
  login is not an act this library performs.

  ## Using it

  A `Phoenix.Presence`, supervised by the host in its application's tree,
  after the PubSub server and before the endpoint:

      children = [
        {Phoenix.PubSub, name: MyApp.PubSub},
        AshQuick.BrowserSessionPresence,
        MyAppWeb.Endpoint
      ]

  It rides the PubSub server the configured `:endpoint` names in its own
  configuration — the one the host's LiveViews already run on — so nothing is
  configured for it. A host whose endpoint is configured under another
  application's name than its own passes `pubsub_server:` in the child spec
  instead.

  Leaving it out of the tree costs the register and nothing else. The mount
  that registers tabs warns once per navigation and carries on serving the
  page, so the app works without it; only the page that reads the register
  fails, which is the page the host has not set up.

  Nothing here is called by a host directly. `AshQuick.LiveView.Mount` is what
  registers a tab, so a host that mounts that stage has a working register by
  construction, and `AshQuick.LiveView.BrowserSessionsLive` is what reads it.
  """

  use Phoenix.Presence, otp_app: :ash_quick

  alias AshQuick.BrowserSession
  alias AshQuick.Config

  require Logger

  @topic "ash_quick:browser_sessions"

  # `Phoenix.Presence` wants the PubSub server in the child spec, and the
  # endpoint's `config/1` is unreadable until the endpoint has started, which is
  # after this. So it is read where the endpoint reads it: the application
  # environment, under the application the endpoint belongs to.
  defoverridable child_spec: 1

  def child_spec(opts) do
    super(Keyword.put_new_lazy(opts, :pubsub_server, &pubsub_server/0))
  end

  @doc "The PubSub topic the presence diffs are broadcast on."
  def topic, do: @topic

  @doc "Subscribes the caller to join/leave diffs on the register's topic."
  def subscribe, do: Phoenix.PubSub.subscribe(pubsub_server(), @topic)

  defp pubsub_server do
    endpoint = Config.endpoint() || raise ArgumentError, no_endpoint()
    app = Application.get_application(endpoint)

    Keyword.get(Application.get_env(app, endpoint, []), :pubsub_server) ||
      raise ArgumentError, """
      #{inspect(__MODULE__)} rides the PubSub server #{inspect(endpoint)} is \
      configured with, and its configuration names none. Configure one on the \
      endpoint, or pass it in the child spec:

          {AshQuick.BrowserSessionPresence, pubsub_server: MyApp.PubSub}
      """
  end

  defp no_endpoint do
    """
    #{inspect(__MODULE__)} rides the PubSub server of the configured endpoint, \
    and none is configured:

        config :ash_quick, endpoint: MyAppWeb.Endpoint
    """
  end

  @doc """
  Registers this LiveView process as a connection of a signed-in tab, and records
  the path it is on.

  Takes the session `AshQuick.LiveView.Mount` built rather than the host's scope.
  Everything below comes out of the connect params and the token, so a scope
  could only carry the same values back in the host's own field names.

  Called once per navigation. The first call registers the connection and every
  one after it moves the path along, so the register says where a tab is rather
  than only that it exists.
  """
  def track_session(%BrowserSession{real_actor: real_actor} = session, path) do
    track_or_update(identifier(real_actor), %{
      # The tab's own identity, minted in the browser. Two processes carrying it
      # are one tab reconnecting, not two people.
      session_id: session.id,
      # What `revoke/1` sends to. Keeping it in the meta is what lets one
      # session be ended from another node without a topic per session.
      pid: self(),
      real_actor_label: label(real_actor),
      # Both nil unless the tab is standing in for somebody, which is how every
      # reader here tells the two kinds of session apart.
      actor_id: identifier(session.actor),
      actor_label: label(session.actor),
      impersonating_since: session.impersonating_since,
      started_at: session.started_at,
      ip: session.ip,
      path: path,
      # When this connection last said so. `started_at` is the tab's and is the
      # same for every connection of a session, so it cannot order them; this is
      # what `sessions/0` reads the freshest connection by.
      at: DateTime.utc_now()
    })
  end

  # A connection is registered once and then moved along. `track/4` refuses the
  # second call as already tracked, which is the signal to update instead — the
  # same process navigating, not a new one. Every other failure is the
  # tracker's, and this register is not worth failing a page load over — which
  # matters more now that the page it would fail is every page.
  defp track_or_update(key, meta) do
    case track(self(), @topic, key, meta) do
      {:ok, _ref} -> :ok
      {:error, {:already_tracked, _pid, _topic, _key}} -> move(key, meta)
      {:error, reason} -> warn(reason)
    end
  rescue
    # Not started is the one failure the tracker cannot return: with no
    # register in the tree there is no table to answer from, and it raises
    # instead. It gets the same treatment as a returned error, or a host that
    # forgot the child spec would find every page 500ing rather than a
    # sidebar's worth of feature missing.
    error -> unsupervised(error)
  end

  defp move(key, meta) do
    case update(self(), @topic, key, meta) do
      {:ok, _ref} -> :ok
      {:error, reason} -> warn(reason)
    end
  end

  defp warn(reason) do
    Logger.warning("could not track browser session: #{inspect(reason)}")
    :ok
  end

  defp unsupervised(error) do
    Logger.warning("""
    could not track browser session: #{Exception.message(error)}

    #{inspect(__MODULE__)} has to be in the host's supervision tree, after the \
    PubSub server and before the endpoint:

        children = [
          {Phoenix.PubSub, name: MyApp.PubSub},
          #{inspect(__MODULE__)},
          MyAppWeb.Endpoint
        ]
    """)

    :ok
  end

  @doc """
  Every signed-in tab open across the cluster, most recent first.

  One entry per session, with the processes currently holding it in `:pids` —
  more than one only for the moment a reconnecting tab's old process takes to
  go away.
  """
  def sessions do
    @topic
    |> list()
    |> Enum.flat_map(fn {real_actor_id, %{metas: metas}} ->
      metas
      |> Enum.group_by(& &1.session_id)
      |> Enum.map(fn {_session_id, connections} -> session(real_actor_id, connections) end)
    end)
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
  end

  defp session(real_actor_id, connections) do
    # The token's claims are the same on every connection of a session, but the
    # path and the address are the connection's own — so the freshest one
    # answers. A reconnecting tab briefly has two, and the one still reporting
    # is the one to believe.
    meta = Enum.max_by(connections, & &1.at, DateTime)

    %{
      id: meta.session_id,
      real_actor_id: real_actor_id,
      real_actor_label: meta.real_actor_label,
      actor_id: meta.actor_id,
      actor_label: meta.actor_label,
      impersonating?: not is_nil(meta.actor_id),
      impersonating_since: meta.impersonating_since,
      started_at: meta.started_at,
      ip: meta.ip,
      path: meta.path,
      pids: Enum.map(connections, & &1.pid)
    }
  end

  @doc """
  Ends the impersonation on session `id`.

  The id is resolved against the tracked sessions rather than trusted, and the
  session it names has to actually be impersonating — an ordinary tab is no
  answer here, so a hand-pushed event cannot reach one. That is the boundary,
  not the button: this library ends impersonations and never ends a login.

  The tab drops its token and reconnects, which remounts it as the real actor.
  """
  def revoke(id) when is_binary(id) do
    case Enum.find(sessions(), &(&1.id == id and &1.impersonating?)) do
      %{pids: pids} ->
        Enum.each(pids, &send(&1, :end_impersonation))
        :ok

      nil ->
        :error
    end
  end

  # The label is the one identifier the resource has declared, so the register
  # names people the same way every other AshQuick surface does. A host wanting
  # more in it points `display do label ... end` at a composed calculation.
  defp label(nil), do: nil

  defp label(record) do
    AshQuick.Info.display_value(record) || to_string(identifier(record))
  end

  defp identifier(nil), do: nil
  defp identifier(record), do: AshQuick.Impersonation.Token.identifier(record)
end
