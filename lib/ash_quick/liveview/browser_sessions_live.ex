defmodule AshQuick.LiveView.BrowserSessionsLive do
  @moduledoc """
  The page a privileged actor finds somebody on: every browser tab signed in
  right now, whose it is, and what page it is looking at.

  A browser session is stored nowhere (see `AshQuick.BrowserSession`), so this
  reads `AshQuick.BrowserSessionPresence` rather than the database, and
  follows its join/leave diffs — a tab that closes or disconnects
  disappears here on its own.

  It answers a support call. Somebody rings up stuck on a page, and instead of
  reading a URL down the phone or describing which filter they applied, they are
  looked up here: their tabs, where each one is, and two ways to go and see it.
  Impersonating tabs are the same list, marked as what they are, and those keep
  the kill switch.

  The host adds a route for it, inside whatever `live_session` supplies the
  `scope` assign:

      live "/browser_sessions", AshQuick.LiveView.BrowserSessionsLive, :index

  and supervises the register it reads, `AshQuick.BrowserSessionPresence`.

  Each row links the person at the tab to `/profile/:id`, so a host that wants
  those links to lead anywhere serves its actor resource there.

  ## Who sees what, and who may do what

  Two different questions, and conflating them is what would make this page
  useless. **Everyone who may reach it sees every signed-in tab.** A register
  that hid rows would be a register nobody could trust to be complete, and there
  is nothing in "somebody is signed in and looking at this page" that a reader
  holding the privilege to stand in for people is not already entitled to know.
  Reading the page at all is the one gate on seeing it: may this actor stand in
  for anybody at all?

  What the host's `:impersonate` policy governs is the **controls**, asked per
  row against whoever the tab is *acting as* — on an ordinary tab that is
  whoever is at it, on one standing in for somebody it is the person being stood
  in for, which is the same question ending an impersonation has always asked.
  A row nobody may act on still shows; it simply offers nothing. Your own tabs
  are the ordinary case of that: they are here, and no host policy lets somebody
  stand in for themselves, so they carry no button.

  The route gate is not the boundary it looks like: a host may deliberately wave
  users through to a page so its layout can render them a notice instead, and a
  privilege lost since the page was opened only lands on the next navigation. So
  the view settles both questions for itself rather than trusting the layout a
  host wraps it in to have swapped its output away.

  Every handler asks the id-independent half first — may this actor stand in for
  anybody at all? — because an id the register does not hold names no record to
  ask about. Whoever fails that is turned away before the register is read, which
  is what keeps "no such session" from being an answer only the authorized were
  supposed to get. Anyone refused is refused outright rather than flashed at,
  because the layout that would have rendered the flash may be exactly the one
  the host swapped out.
  """

  use Phoenix.LiveView
  use Gettext, backend: AshQuick.Gettext

  import AshQuick.Components

  alias AshQuick.BrowserSessionPresence
  alias AshQuick.Config
  alias AshQuick.Impersonation
  alias AshQuick.LiveView.ActionErrors
  alias Phoenix.Socket.Broadcast

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: BrowserSessionPresence.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Live Users")
     |> assign(:search, "")
     |> assign(:impersonations_only, false)
     |> assign(:actors, %{})
     |> assign_sessions()}
  end

  @impl true
  def handle_info(%Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign_sessions(socket)}
  end

  # A host's auth hooks pass on anything they don't recognise, so this view is
  # the end of the line for messages it never asked for.
  def handle_info(_message, socket), do: {:noreply, socket}

  # One form, so a change to either half arrives carrying the other's current
  # value rather than the page having to remember it.
  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:search, Map.get(params, "search", ""))
     |> assign(:impersonations_only, Map.get(params, "impersonations_only") == "true")
     |> assign_sessions()}
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    with_session(socket, id, fn session, socket ->
      authorize!(target_id(session), socket.assigns.scope, id)
      revoke(session, socket)
    end)
  end

  # Going to look at what somebody is looking at, as them. The same act the
  # detail page offers, started from the other end: the tab is already on a
  # page, so the token carries where to land.
  def handle_event("impersonate", %{"id" => id}, socket) do
    with_session(socket, id, fn session, socket ->
      target = authorize!(target_id(session), socket.assigns.scope, id)
      impersonate(target, session, socket)
    end)
  end

  # Every handler is the same shape: settle whether this actor may stand in for
  # anybody before the register is read, resolve the id against it, and leave the
  # per-record question to the handler itself. Seeing a row and being allowed to
  # act on it are different answers, so an id that has ended is told so and an id
  # nobody may act on is refused outright.
  defp with_session(socket, id, fun) do
    authorize_actor!(socket.assigns.scope)

    case Enum.find(current_sessions(socket), &(&1.id == id)) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "That session has already ended.")
         |> assign_sessions()}

      session ->
        fun.(session, socket)
    end
  end

  defp revoke(%{id: id}, socket) do
    case BrowserSessionPresence.revoke(id) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Impersonation ended.")}

      # The tab went away between the lookup and the send.
      :error ->
        {:noreply,
         socket
         |> put_flash(:error, "That session has already ended.")
         |> assign_sessions()}
    end
  end

  defp impersonate(target, session, socket) do
    scope = socket.assigns.scope

    case Ash.update(target, %{}, action: Impersonation.action(), scope: scope) do
      {:ok, _target} ->
        token = Impersonation.Token.sign(AshQuick.Scope.real_actor(scope), target)

        # The destination rides along with the token so the tab arrives already
        # being somebody else, rather than landing as itself and swapping under
        # whoever is reading it.
        {:noreply, push_event(socket, "impersonate", %{token: token, to: session.path || "/"})}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ActionErrors.user_facing_message(error))}
    end
  end

  # Who the tab is acting as, which is both who a reader of this page would be
  # reaching for and who every permission here is asked about. An impersonating
  # tab is being somebody; an ordinary one is only whoever is at it.
  defp target_id(%{actor_id: nil, real_actor_id: real_actor_id}), do: real_actor_id
  defp target_id(%{actor_id: actor_id}), do: actor_id

  # The record is fetched unauthorized and untenanted on purpose: what matters is
  # the right to stand in for them, neither the right to read them nor which
  # tenant the watcher happens to be in. A host whose read policy hides a user
  # from an admin who may still cut their session off, or whose admin has pinned
  # themselves to one tenant while the session runs in another, would otherwise
  # lose the kill switch. A record that has since been deleted is nobody's to
  # stand in for either.
  defp authorize!(actor_id, scope, session_id) do
    case fetch_actor(actor_id, scope) do
      %{} = actor ->
        if may_impersonate?(actor, scope), do: actor, else: refuse!(scope, session_id)

      nil ->
        refuse!(scope, session_id)
    end
  end

  defp fetch_actor(nil, _scope), do: nil

  defp fetch_actor(actor_id, scope) do
    case Ash.get(Impersonation.resource!(), actor_id,
           scope: scope,
           authorize?: false,
           tenant: nil
         ) do
      {:ok, actor} -> actor
      {:error, _reason} -> nil
    end
  end

  defp may_impersonate?(actor, scope) do
    Ash.can?({actor, Impersonation.action()}, scope, tenant: nil)
  end

  # The same question with nobody named: may this actor stand in for anybody at
  # all? It is answerable without a record because what rules an actor out
  # entirely — a role check — needs none, while the part of a policy that does
  # need one is a filter, which pre-flight authorization reports as `:maybe` and
  # `Ash.can?/3` reads as yes. So it turns away whoever could never hold any of
  # this and leaves naming the target to `authorize!/3`.
  defp authorize_actor!(scope) do
    if may_impersonate_anybody?(scope), do: :ok, else: refuse!(scope)
  end

  defp may_impersonate_anybody?(scope) do
    Ash.can?({Impersonation.resource!(), Impersonation.action()}, scope, tenant: nil)
  end

  defp refuse!(scope, session_id \\ nil) do
    raise AshQuick.Impersonation.NotAllowedError,
      session_id: session_id,
      actor: AshQuick.Scope.actor(scope)
  end

  # The register is read whole by an actor who could stand in for somebody. An
  # actor who may stand in for nobody is shown nothing, which is the same answer
  # they would get if nobody were signed in.
  defp assign_sessions(socket) do
    socket = resolve_actors(socket, tracked(socket))
    sessions = current_sessions(socket)

    socket
    |> assign(:sessions, sessions)
    |> assign(:groups, group(filter(sessions, socket.assigns)))
  end

  defp tracked(socket) do
    if may_impersonate_anybody?(socket.assigns.scope),
      do: BrowserSessionPresence.sessions(),
      else: []
  end

  # Read fresh rather than off the assign: a handler resolving an id is asking
  # what is tracked now, not what was drawn.
  defp current_sessions(socket) do
    %{scope: scope, actors: actors} = socket.assigns

    socket
    |> tracked()
    |> Enum.map(&Map.put(&1, :openable?, allowed?(actors[target_id(&1)], scope)))
  end

  # Whether this row offers anything, which is the only thing the per-record
  # policy decides here. A target that has since been deleted is nobody's to
  # stand in for.
  defp allowed?(nil, _scope), do: false
  defp allowed?(actor, scope), do: may_impersonate?(actor, scope)

  # Every diff re-renders the page, and a diff is now every navigation of every
  # tab, so re-reading the same handful of people each time is the one cost here
  # that would grow with how busy the place is. They are kept for as long as the
  # page is open; the permission is re-asked on every render regardless, which is
  # what a privilege lost mid-session has to land on.
  defp resolve_actors(socket, sessions) do
    scope = socket.assigns.scope

    missing =
      sessions
      |> Enum.map(&target_id/1)
      |> Enum.reject(&(is_nil(&1) or Map.has_key?(socket.assigns.actors, &1)))
      |> Enum.uniq()

    assign(
      socket,
      :actors,
      Enum.into(missing, socket.assigns.actors, &{&1, fetch_actor(&1, scope)})
    )
  end

  defp filter(sessions, %{search: search, impersonations_only: impersonations_only}) do
    search = String.trim(search)

    Enum.filter(sessions, fn session ->
      (not impersonations_only or session.impersonating?) and matches?(session, search)
    end)
  end

  defp matches?(_session, ""), do: true

  # Both names, because somebody ringing up about a user is as likely to be
  # found in the row where a colleague is standing in for them as in their own.
  defp matches?(session, search) do
    [session.real_actor_label, session.actor_label]
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(&String.contains?(String.downcase(&1), String.downcase(search)))
  end

  # One group per person at a browser, because that is the unit somebody rings
  # up about: they have a name and they have two tabs open, one of which is
  # wrong.
  defp group(sessions) do
    sessions
    |> Enum.group_by(& &1.real_actor_id)
    |> Enum.map(fn {real_actor_id, sessions} ->
      %{
        id: real_actor_id,
        label: sessions |> List.first() |> Map.fetch!(:real_actor_label),
        sessions: Enum.sort_by(sessions, & &1.started_at, {:desc, DateTime})
      }
    end)
    |> Enum.sort_by(& &1.label)
  end

  # The detail page of whoever a tab is. Fixed rather than derived: the actor
  # resource is routed at more than one path in a host that has both an admin
  # listing and a self-service page, and nothing in a route can say which of the
  # two an actor belongs on. `/profile` is the one every host has.
  defp actor_path(actor_id), do: "/profile/#{actor_id}"

  @impl true
  def render(assigns) do
    ~H"""
    <section class="p-3 sm:p-5">
      <div class="mx-auto">
        <div class="card bg-base-100 shadow-md border border-base-300 rounded-2xl">
          <div class="card-body p-4 sm:p-6">
            <.header>
              <.icon name="hero-user-circle" class="w-6 h-6 inline-block me-2" /> {gettext(
                "Live Users"
              )}
              <:subtitle>
                {gettext(
                  "Everyone signed in right now, the tabs they have open, and the page each one is on. A tab drops off this list when it is closed, signs out, or loses its connection."
                )}
              </:subtitle>
            </.header>

            <form
              id="browser-sessions-filter-form"
              phx-change="filter"
              class="mt-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between"
            >
              <label for="session-search" class="sr-only">{gettext("Search by name")}</label>
              <label class="input input-sm w-full sm:max-w-xs">
                <.icon name="hero-magnifying-glass" class="w-4 h-4 opacity-50" />
                <input
                  type="text"
                  id="session-search"
                  name="search"
                  value={@search}
                  placeholder={gettext("Search by name")}
                  phx-debounce={120}
                  class="grow"
                />
              </label>

              <label class="flex items-center gap-2 text-sm cursor-pointer shrink-0">
                <%!-- An unchecked box sends no param, so the hidden one ahead of
                it is what makes "off" a value the server receives rather than an
                absence it has to guess at. --%>
                <input type="hidden" name="impersonations_only" value="false" />
                <input
                  type="checkbox"
                  name="impersonations_only"
                  value="true"
                  class="toggle toggle-sm"
                  checked={@impersonations_only}
                /> {gettext("Impersonations only")}
              </label>
            </form>

            <div :if={@groups == []} class="py-10 text-center text-base-content/60">
              <.icon name="hero-user-circle" class="w-10 h-10 mx-auto mb-2 opacity-40" />
              <p>{empty_message(@sessions, @search, @impersonations_only)}</p>
            </div>

            <div :if={@groups != []} id="browser-sessions" class="mt-4 flex flex-col gap-5">
              <div :for={group <- @groups} id={"person-#{group.id}"}>
                <div class="flex items-baseline gap-2 mb-2">
                  <.link
                    navigate={actor_path(group.id)}
                    class="link link-hover font-semibold truncate"
                  >
                    {group.label}
                  </.link>
                  <span class="text-xs text-base-content/50">
                    {tab_count(group.sessions)}
                  </span>
                </div>

                <!-- One card per tab rather than a row: each carries two people
                     plus a URL, which a table can only fit by scrolling
                     sideways on anything narrow. -->
                <div class="flex flex-col gap-3">
                  <div
                    :for={session <- group.sessions}
                    id={"session-#{session.id}"}
                    class="card bg-base-200 border border-base-300 rounded-xl"
                  >
                    <div class="card-body p-4 gap-4 lg:flex-row lg:items-center lg:justify-between">
                      <div class="flex flex-col gap-4 min-w-0 sm:flex-row sm:gap-8">
                        <.field label={gettext("Acting as")} class="min-w-0 sm:flex-1">
                          <div :if={session.impersonating?} class="flex flex-col gap-0 min-w-0">
                            <.link
                              navigate={actor_path(session.actor_id)}
                              class="link link-hover font-semibold truncate"
                            >
                              {session.actor_label}
                            </.link>
                            <span class="badge badge-warning badge-sm mt-1 w-fit">
                              {gettext("Impersonating")}
                            </span>
                          </div>
                          <p :if={not session.impersonating?} class="text-sm text-base-content/60">
                            {gettext("Themselves")}
                          </p>
                        </.field>

                        <.field label={gettext("Started")} class="min-w-0 sm:flex-1">
                          <p class="text-sm">{Config.format_datetime(session.started_at)}</p>
                          <p :if={session.ip} class="text-sm text-base-content/60">
                            {gettext("from %{ip}", ip: session.ip)}
                          </p>
                        </.field>

                        <.field label={gettext("Now viewing")} class="min-w-0 sm:flex-1">
                          <%!-- A new tab, because this page is a live picture of
                          something moving: following the link in place loses the
                          register you were watching it on. It goes with the
                          reader's own permissions, which the label says, because
                          a page that renders differently for them is exactly how
                          a support call ends in the wrong answer. --%>
                          <.link
                            :if={session.path}
                            href={session.path}
                            target="_blank"
                            class="link link-hover block text-sm font-mono truncate"
                            title={session.path}
                          >
                            {session.path}
                          </.link>
                          <p :if={is_nil(session.path)} class="text-sm text-base-content/40">
                            {gettext("Not on a page")}
                          </p>
                        </.field>
                      </div>

                      <div class="flex flex-col gap-2 lg:flex-row lg:items-center shrink-0">
                        <button
                          :if={session.openable? and session.path}
                          type="button"
                          class="btn btn-sm btn-primary"
                          phx-click="impersonate"
                          phx-value-id={session.id}
                        >
                          <.icon name="hero-eye" class="w-4 h-4" /> {gettext("Open as them")}
                        </button>

                        <.end_session_button
                          :if={session.impersonating? and session.openable?}
                          session_id={session.id}
                        />
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp tab_count(sessions) do
    count = length(sessions)
    ngettext("%{count} tab", "%{count} tabs", count, count: count)
  end

  # The three ways this page is empty are three different pieces of news, and
  # only one of them means nobody is here.
  defp empty_message([], _search, _impersonations_only),
    do: gettext("Nobody is signed in right now.")

  defp empty_message(_sessions, _search, true),
    do: gettext("Nobody is impersonating anyone right now.")

  defp empty_message(_sessions, _search, _impersonations_only),
    do: gettext("Nobody matches that name.")

  # The card has no header row to name its columns, so each value carries its
  # own label.
  attr(:label, :string, required: true)
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  defp field(assigns) do
    ~H"""
    <div class={@class}>
      <p class="text-xs uppercase tracking-wider text-base-content/40 mb-0.5">{@label}</p>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr(:session_id, :string, required: true)
  attr(:class, :string, default: nil)

  defp end_session_button(assigns) do
    ~H"""
    <button
      type="button"
      class={["btn btn-sm btn-error", @class]}
      phx-click="revoke"
      phx-value-id={@session_id}
    >
      <.icon name="hero-x-mark" class="w-4 h-4" /> {gettext("End session")}
    </button>
    """
  end
end
