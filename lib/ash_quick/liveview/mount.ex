defmodule AshQuick.LiveView.Mount do
  @moduledoc """
  What AshQuick establishes on every mount, before the host has a scope.

  A host's scope is built out of things only the connection knows: who this tab
  is standing in for, and the address it came from. Neither can be worked out
  from the session cookie, and both have to exist before `MyApp.Scope.new/1` is
  called. This is the stage that puts them there.

      on_mount: [
        AshQuick.LiveView.Mount,
        {MyAppWeb.UserAuth, :assign_scope},
        {MyAppWeb.UserAuth, :require_user}
      ]

  It goes first. Everything after it can read what it found:

      scope =
        MyApp.Scope.new(
          actor: socket.assigns.current_user,
          impersonating: AshQuick.LiveView.Mount.actor(socket),
          ip: AshQuick.LiveView.Mount.ip(socket)
        )

  The actor it reads is `socket.assigns.current_user` unless the host says
  otherwise with `:actor_assign`; see `AshQuick.Config`. That assign is set by
  whatever put the session on the socket, which is why this can run before the
  host's own stages rather than after them.

  ## The browser session

  A tab names itself in the LiveSocket connect params — an id it minted into
  `sessionStorage` and replays on every connect — so a session only exists once
  the client has connected. A disconnected render has no tab to speak of, which
  is the same reason it is always the real actor.

  That id is the browser's to mint because the server cannot: a refresh or a
  reconnect hands it a brand new process, with no way to tell that apart from a
  second tab opening. See `AshQuick.BrowserSession`.

  A tab whose client does not name itself still gets a session if it is
  impersonating, identified by the token instead. That is what identified a tab
  before tabs named themselves at all, so a host serving an older
  `browser_session.js` keeps its kill switch and loses only the ordinary
  sessions from its register, rather than losing both.

  ## Impersonation

  A tab carries its impersonation in the same connect params
  (`AshQuick.Impersonation.Token`). Resolving it does not make a different
  session — it is a state the same tab is in, so the tab keeps its id and its
  place in the register and gains whoever it is acting as.

  A token this mount refuses, because it expired, was minted by somebody else,
  or was minted before its holder lost the privilege, is cleared from the tab
  so it stops being replayed. The tab is still itself and still registers as
  itself. The policy is re-run on every mount rather than trusted from the
  token, which is what makes a revoked privilege land on the next navigation.

  Two hooks go on:

    * `handle_params` — registers the tab, then keeps its current path current.
      Every signed-in tab gets this one.

    * `handle_info` — the receiving end of
      `AshQuick.BrowserSessionPresence.revoke/1`. Someone watching the live
      sessions ends one from another browser, and this is what turns that into
      the tab dropping its token and reconnecting as its real actor. Only a tab
      standing in for somebody gets this one: there is nothing to revoke on a
      tab that is only itself, and ending a login is not an act this library
      performs.

  ## Why registering rides `handle_params`

  Because it is what makes the register worth reading. `handle_params` runs once
  at mount and again on every navigation, so the same hook that registers the tab
  reports where it has moved to — and `AshQuick.LiveView.BrowserSessionsLive`
  answers "who is signed in, and what are they looking at" rather than just the
  first half. That is the whole of its use: somebody rings up stuck on a page,
  and the page they are stuck on is the thing nobody can describe down a phone.

  What it reports is the whole path, query included, because that is where a
  QuickView keeps the search, the filters and the record being edited.

  It costs one `Phoenix.Presence` update per navigation, which is what broadcasts
  the change to anybody watching.

  **This records where signed-in tabs are, and who may read it is not this
  stage's decision.** The register gates every row on the host's own
  `:impersonate` policy — you may see where somebody is exactly when you could
  stand in for them — so a host narrows what is observable by narrowing that,
  not by narrowing this.

  A LiveView not mounted at the router has no `handle_params` at all — LiveView
  refuses the hook outright rather than dropping it quietly — so such a mount
  registers once, without a path, and reports nowhere rather than crashing.

  ## The IP

  `connect_ip/1` reads an `X-Forwarded-For` ahead of the peer address. It is
  here because it shares the scope's deadline and comes off the socket, not
  because it has anything to do with impersonation.

  It needs both keys on the endpoint:

      socket "/live", Phoenix.LiveView.Socket,
        websocket: [connect_info: [:peer_data, :x_headers, session: @session_options]]

  A missing one is not an error anywhere. `connect_ip/1` answers `nil` and
  every audited write quietly records no address, which is why
  `connect_info_violations/1` exists for a test to assert on. See
  `AshQuick.Scope.contract_violations/1`, which is there for the same reason.
  """

  alias AshQuick.BrowserSession
  alias AshQuick.BrowserSessionPresence
  alias AshQuick.Config
  alias AshQuick.Impersonation.Token
  alias Phoenix.Component
  alias Phoenix.LiveView

  @session_assign :ash_quick_browser_session
  @ip_assign :ash_quick_connect_ip

  @required_connect_info [:peer_data, :x_headers]

  @doc """
  Resolves the tab's browser session and the connection's address, and assigns
  both.

  Assigns them whether or not there was a session to find: a mount with nobody
  signed in still came from somewhere, and `ip/1` has to answer for it.
  """
  def on_mount(:default, _params, _session, socket) do
    real_actor = socket.assigns[Config.actor_assign()]
    {session, socket} = resolve(socket, real_actor)

    {:cont,
     socket
     |> Component.assign(@session_assign, session)
     |> Component.assign(@ip_assign, connect_ip(socket))
     |> attach_hooks(session)}
  end

  @doc """
  The actor this tab is standing in for, or `nil` when it is nobody but itself.

  What the host passes to its scope as the impersonated actor.
  """
  def actor(socket) do
    case browser_session(socket) do
      %BrowserSession{actor: actor} -> actor
      nil -> nil
    end
  end

  @doc """
  The tab's session, or `nil` when nobody is signed in or nothing named the tab.

  See `AshQuick.BrowserSession`.
  """
  def browser_session(socket), do: socket.assigns[@session_assign]

  @doc """
  The address this connection came from, or `nil` off a disconnected mount or
  an endpoint offering neither `:x_headers` nor `:peer_data`.
  """
  def ip(socket), do: socket.assigns[@ip_assign]

  @doc """
  The address `socket` connected from, preferring a proxy's forwarded header
  over the peer address.

  `nil` on a disconnected mount, which has no connection to describe yet.
  """
  def connect_ip(socket), do: forwarded_ip(socket) || peer_ip(socket)

  @doc """
  The ways `endpoint` falls short of what `connect_ip/1` needs, as a list of
  sentences — empty when it satisfies it.

  Nothing calls this on a host's behalf. A missing `connect_info` key is
  indistinguishable at runtime from a request that genuinely had no forwarded
  header, so the only place it can be caught is a test asserting this is empty.
  """
  def connect_info_violations(endpoint) when is_atom(endpoint) do
    cond do
      not Code.ensure_loaded?(endpoint) ->
        ["#{inspect(endpoint)} is not a loadable module."]

      not function_exported?(endpoint, :__sockets__, 0) ->
        ["#{inspect(endpoint)} is not a Phoenix endpoint, so it declares no sockets."]

      true ->
        live_socket_violations(endpoint)
    end
  end

  defp live_socket_violations(endpoint) do
    case Enum.filter(endpoint.__sockets__(), &live_socket?/1) do
      [] ->
        [
          "#{inspect(endpoint)} declares no Phoenix.LiveView.Socket, so nothing " <>
            "mounts through it."
        ]

      sockets ->
        Enum.flat_map(sockets, &transport_violations(endpoint, &1))
    end
  end

  defp live_socket?({_path, Phoenix.LiveView.Socket, _opts}), do: true
  defp live_socket?(_socket), do: false

  defp transport_violations(endpoint, {path, _module, opts}) do
    for transport <- [:websocket, :longpoll],
        config = Keyword.get(opts, transport),
        config,
        missing = missing_connect_info(config),
        missing != [] do
      "#{inspect(endpoint)} serves #{path} over #{transport} without " <>
        "#{Enum.map_join(missing, " or ", &inspect/1)} in `:connect_info`, so " <>
        "`#{inspect(__MODULE__)}.connect_ip/1` has nothing to read and every " <>
        "audited write records no IP."
    end
  end

  # `true` is the shorthand for a transport left at its defaults, which offers
  # no connect info at all.
  defp missing_connect_info(true), do: @required_connect_info

  defp missing_connect_info(config) when is_list(config) do
    declared = Keyword.get(config, :connect_info, [])
    Enum.reject(@required_connect_info, &(&1 in declared))
  end

  defp missing_connect_info(_config), do: @required_connect_info

  # Nobody signed in is no session: a sign-in page has nobody to register and
  # nobody to stand in for.
  defp resolve(socket, nil), do: {nil, socket}

  defp resolve(socket, real_actor) do
    case LiveView.get_connect_params(socket) do
      params when is_map(params) ->
        {impersonation, socket} = impersonation(params, socket, real_actor)
        {session(params, impersonation, real_actor, socket), socket}

      # A disconnected render carries no params at all, so it has no tab to
      # name — which is the same reason it is always the real actor.
      _params ->
        {nil, socket}
    end
  end

  # `nil` covers both "replayed no token" and "replayed one we refused". The two
  # differ only in whether the tab is told to stop replaying it.
  defp impersonation(%{"impersonation" => token}, socket, real_actor) when is_binary(token) do
    case Token.resolve(token, real_actor) do
      nil -> {nil, LiveView.push_event(socket, "clear-impersonation", %{})}
      resolved -> {resolved, socket}
    end
  end

  defp impersonation(_params, socket, _real_actor), do: {nil, socket}

  # The tab names itself in the connect params.
  defp session(%{"tab" => %{"id" => id} = tab}, impersonation, real_actor, socket)
       when is_binary(id) do
    build(id, opened_at(tab), impersonation, real_actor, socket)
  end

  # A tab that does not name itself is still identified by the impersonation it
  # carries, which is what identified it before tabs named themselves at all. So
  # a host serving an older `browser_session.js` keeps its kill switch and loses
  # only the ordinary sessions from the register, rather than losing both.
  defp session(
         _params,
         {_actor, %{id: id, started_at: started_at}} = impersonation,
         real_actor,
         socket
       ) do
    build(id, started_at, impersonation, real_actor, socket)
  end

  # Nothing names this tab and it is standing in for nobody. There is no session
  # to register and nothing a register could say about it.
  defp session(_params, nil, _real_actor, _socket), do: nil

  defp build(id, started_at, impersonation, real_actor, socket) do
    %BrowserSession{
      id: id,
      real_actor: real_actor,
      started_at: started_at,
      ip: connect_ip(socket)
    }
    |> impersonating(impersonation)
  end

  defp impersonating(%BrowserSession{} = session, nil), do: session

  # The impersonation does not replace the session, it is a state of it: same
  # tab, same id, same place in the register, now acting as somebody else. Its
  # own start time comes from the signed token and is the one a kill-switch
  # decision rests on.
  defp impersonating(%BrowserSession{} = session, {actor, %{started_at: started_at}}) do
    %BrowserSession{session | actor: actor, impersonating_since: started_at}
  end

  # The tab's claim about when it was opened. Shown, never trusted — opening a
  # tab is not a privilege, so there is nothing here to lie your way into. A
  # value that will not parse is treated as a tab that has only just said hello.
  defp opened_at(%{"started_at" => started_at}) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, at, _offset} -> at
      {:error, _reason} -> DateTime.utc_now()
    end
  end

  defp opened_at(_tab), do: DateTime.utc_now()

  defp attach_hooks(socket, nil), do: socket

  defp attach_hooks(socket, %BrowserSession{} = session) do
    socket
    |> attach_revoke_hook(session)
    |> attach_tracking_hook(session)
  end

  # Nothing to revoke on a tab that is only itself, and the register offers no
  # control that would send here — ending an impersonation is not the same act
  # as ending somebody's login, and this library does not do the second.
  defp attach_revoke_hook(socket, %BrowserSession{actor: nil}), do: socket

  # A privileged actor watching the live sessions ends one from another browser.
  # The tab drops its token and reconnects, remounting as its real actor — the
  # same thing `AshQuick.LiveView.Impersonation.end_impersonation/1` does from
  # the tab's own menu.
  defp attach_revoke_hook(socket, %BrowserSession{}) do
    LiveView.attach_hook(socket, :ash_quick_end_impersonation, :handle_info, fn
      :end_impersonation, socket ->
        {:halt, LiveView.push_event(socket, "end-impersonation", %{})}

      _message, socket ->
        {:cont, socket}
    end)
  end

  # Registering and reporting are one hook because they are one question asked
  # repeatedly: where is this tab now? The first answer registers it.
  defp attach_tracking_hook(%{router: nil} = socket, session) do
    track(session, nil)
    socket
  end

  defp attach_tracking_hook(socket, session) do
    LiveView.attach_hook(socket, :ash_quick_track_browser_session, :handle_params, fn
      _params, uri, socket ->
        track(session, path(uri))
        {:cont, socket}
    end)
  end

  defp track(session, path), do: BrowserSessionPresence.track_session(session, path)

  # The query is where a QuickView keeps its search, filters, page and open
  # modal, so a bare path would report every one of them as the same place.
  defp path(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{path: path, query: nil} -> path
      %URI{path: path, query: query} -> path <> "?" <> query
    end
  end

  defp path(_uri), do: nil

  defp forwarded_ip(socket) do
    with headers when is_list(headers) <- LiveView.get_connect_info(socket, :x_headers),
         {_key, value} <- Enum.find(headers, &forwarded?/1),
         address <- value |> String.split(",") |> List.first() |> String.trim(),
         {:ok, ip} <- address |> String.to_charlist() |> :inet.parse_address() do
      format(ip)
    else
      _other -> nil
    end
  end

  defp forwarded?({key, _value}), do: key in ~w(x-forwarded-for x-real-ip)

  defp peer_ip(socket) do
    case LiveView.get_connect_info(socket, :peer_data) do
      %{address: address} -> format(address)
      _other -> nil
    end
  end

  defp format(address), do: address |> :inet.ntoa() |> to_string()
end
