defmodule AshQuick.Impersonation.Token do
  @moduledoc """
  Per-tab impersonation: letting one privileged actor browse as somebody else.

  Impersonation belongs to a browser tab, not to the actor's account. `sign/2`
  mints a token the client keeps in `sessionStorage` and replays in the
  LiveSocket connect params, and `resolve/2` turns that token back into the
  impersonated actor, and the session it belongs to, on every mount. Two tabs
  can therefore be two different people at once, and closing a tab ends its
  impersonation.

  Nothing outside the browser is ever impersonated — an API request
  authenticates with a bearer token and carries no connect params, so there is
  nowhere for a tab's impersonation to ride along. That holds because the only
  reader of the token is the host's `on_mount`, which reads it from
  `Phoenix.LiveView.get_connect_params/1` and from nowhere else.

  The token is signed and pinned to the actor who minted it, so it does nothing
  in anybody else's browser. It is still only a claim by the client, so
  `resolve/2` re-runs the impersonation policy on every mount: losing the
  privilege takes effect on the next navigation, not at the next login. Because
  it grants no more than the session that minted it already had, it is no more
  sensitive than the session cookie itself.

  ## What a host wires

  Not the action the two ends authorize against: AshQuick generates that on the
  configured `:actor_resource` (see `AshQuick.Impersonation`). What the host
  writes is the policy on it, saying who may stand in for whom.

  Point the library at the endpoint that signs the token, and supervise the
  register of signed-in tabs, `AshQuick.BrowserSessionPresence`, in the
  application's tree:

      config :ash_quick, endpoint: MyAppWeb.Endpoint

  Then two call sites, which are host code because each of them is a decision
  AshQuick has no standing to make:

    * a host page offering it calls `sign/2` and pushes the token to the browser
      as an `"impersonate"` event, after running the action so the policy
      refuses whoever it should and the audit log records who did it — the
      detail page of whoever is being stood in for, typically;
    * a route points at `AshQuick.LiveView.BrowserSessionsLive`, which offers
      the same thing from the other end and needs no host code to do it.

  Resolving the token on mount and registering the tab are not among them:
  `AshQuick.LiveView.Mount` does both, so a host that names that stage has
  them by construction.

  The client half is `assets/js/ash_quick/browser_session.js`.
  """

  alias AshQuick.Config
  alias AshQuick.Impersonation

  # Namespaced independently of the token's payload so a host rotating its
  # endpoint secret is the only thing that invalidates outstanding tokens.
  @salt "ash_quick:impersonation"

  @doc """
  Mints the token that puts one browser tab into `target`'s shoes.

  Pinned to `real_actor` so it resolves only in the session that minted it.

  It also names the session it starts. The token is the only thing about an
  impersonation that outlives a single connection, so anything that has to
  survive a refresh — the identity of the session and the moment it began —
  has to ride along in it.
  """
  def sign(real_actor, target) do
    Phoenix.Token.sign(endpoint!(), @salt, %{
      real_actor_id: identifier(real_actor),
      actor_id: identifier(target),
      session_id: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
      started_at: DateTime.utc_now()
    })
  end

  @doc """
  Resolves a tab's token to `{impersonated_actor, session}`, or `nil`.

  The session is what the token says about itself — `:id` and `:started_at`,
  both fixed when it was minted — so every connection this tab makes resolves
  to the same session rather than looking like a new one.

  `nil` covers every way this can legitimately come up empty — no token, a tab
  that outlived it, a token minted for somebody else, a target that has since
  been deleted or become unimpersonatable — because all of them mean the same
  thing to the caller: this tab is nobody but `real_actor`.

  The policy is re-run here rather than trusted from the token, so a privilege
  lost since it was minted lands on the next navigation.
  """
  def resolve(token, real_actor)

  def resolve(token, real_actor) when is_binary(token) and not is_nil(real_actor) do
    resource = Impersonation.resource!()
    real_actor_id = identifier(real_actor)

    with {:ok, %{real_actor_id: ^real_actor_id} = claims} <-
           Phoenix.Token.verify(endpoint!(), @salt, token, max_age: max_age()),
         %{actor_id: actor_id, session_id: session_id, started_at: started_at} <- claims,
         {:ok, target} <- Ash.get(resource, actor_id, actor: real_actor),
         true <- Ash.can?({target, Impersonation.action()}, real_actor) do
      {target, %{id: session_id, started_at: started_at}}
    else
      _ -> nil
    end
  end

  def resolve(_token, _real_actor), do: nil

  @doc false
  # A token only ever names a record of the actor resource — it is the one
  # resource an actor can be resolved from — so its primary key is what a token
  # names, and a composite one has no single value to carry.
  def identifier(%resource{} = record) do
    case Ash.Resource.Info.primary_key(resource) do
      [field] ->
        Map.fetch!(record, field)

      fields ->
        raise ArgumentError,
              "#{inspect(resource)} has a composite primary key (#{inspect(fields)}), which " <>
                "an impersonation token cannot name. Impersonation needs an actor resource " <>
                "identified by a single field."
    end
  end

  defp max_age, do: Config.impersonation_max_age()

  defp endpoint! do
    Config.endpoint() ||
      raise ArgumentError, """
      Impersonation tokens are signed with an endpoint's secret, and none is \
      configured:

          config :ash_quick, endpoint: MyAppWeb.Endpoint
      """
  end
end
