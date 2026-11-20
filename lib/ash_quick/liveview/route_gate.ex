defmodule AshQuick.LiveView.RouteGate do
  @moduledoc """
  Refuses a navigation to a route the scope was not granted.

  `AshQuick.AccessControl` says which routes a scope may navigate to, and the
  nav draws only those. This stage is what makes the list binding: without it a
  route no role was granted still serves its page to anybody who types the URL.
  Resource policies still decide which records that page shows, so what an
  ungated route exposes is pages rather than rows, but it is exposed.

  It goes in the `on_mount` of every live session serving QuickViews, after the
  stage that assigns `@scope` and after the one that sends a visitor with
  nobody signed in to the sign-in page:

      live_session :authenticated,
        on_mount: [
          AshQuick.LiveView.Mount,
          {MyAppWeb.UserAuth, :assign_scope},
          {MyAppWeb.UserAuth, :require_user},
          AshQuick.LiveView.RouteGate
        ] do
        quick_view "/products", MyAppWeb.ProductLive.Quick
      end

  Ahead of the sign-in check it would answer a signed-out visitor with a 403
  rather than with the sign-in page. `mix ash_quick.check` reports a QuickView
  routed in a live session without it as `:ungated_quick_view`.

  ## What it asks

  The access control the configured nav names (`config :ash_quick, nav:`), or
  the one given as `access_control:`. It calls `routes_for/1` with
  `socket.assigns.scope` and matches the path the way the nav does
  (`AshQuick.Nav.Info.allowed?/2`): `/products` covers `/products` and
  `/products/123`, but not `/products_archive`. The sidebar and the gate
  therefore cannot disagree about a path.

  It asks on every `handle_params`, not only on mount, so a live patch or a
  navigation inside the live session is refused the same way a fresh load is.
  Only the path is matched; the query string, where a QuickView keeps its
  filters and its open action, is not. It is matched as the router reads it,
  with empty segments dropped, so `//users` is refused exactly as `/users` is.

  With no access control to ask it raises when the page mounts. A gate that
  answered yes for want of a list would be the gap it exists to close.

  A scope it is asked about gets exactly the routes `routes_for/1` names, and
  nothing else. A host whose own gate let some scopes reach any page, so its
  layout could show them a notice instead, grants those scopes their routes
  there, or keeps its gate and names it to `mix ash_quick.check` as
  `check: [gates: [...]]` (see `AshQuick.Check`).

  ## What a refusal looks like

  It raises `AshQuick.LiveView.RouteGate.NotAllowedError`, which Plug answers
  with a 403, so reaching past a missing sidebar link is a visible refusal
  rather than an empty page.

  A tab standing in for somebody else (`AshQuick.LiveView.Mount.actor/1`) is
  sent to the fallback path with a flash instead. Its first render ran as the
  real actor, who may hold the route, so raising would fail only the connected
  mount, and the reload the client answers with would land on the same page and
  fail again. The fallback is `"/"` unless `fallback:` says otherwise, and it
  should be a route every role holds: a tab refused the fallback itself is
  refused with the error. The fallback is compared by its path, as the router
  reads it, so a query string or a trailing slash on it changes nothing.

  ## Options

  Given as the hook's argument, `{AshQuick.LiveView.RouteGate, opts}`:

    * `:access_control` — the `AshQuick.AccessControl` to ask. Defaults to the
      one the configured nav declares.
    * `:fallback` — where a refused impersonating tab is sent. Defaults to
      `"/"`.

  A LiveView that is not the root of a routed page has no path of its own and
  is not gated: one rendered from a controller, and one `live_render/3`ed
  inside another LiveView, sticky or not, whose page was gated. A view that
  declares the gate with `on_mount` can therefore also be rendered nested.
  """

  use Gettext, backend: AshQuick.Gettext

  alias AshQuick.Config
  alias AshQuick.LiveView.Mount
  alias AshQuick.Nav.Info
  alias Phoenix.LiveView

  defmodule NotAllowedError do
    @moduledoc """
    Raised when a scope navigates to a route its access control does not grant.

    Carries `plug_status: 403`, so Plug answers it as Forbidden. `:path` is the
    path that was refused and `:actor` the actor the scope named, if any.
    """
    defexception [:path, :actor, plug_status: 403]

    @impl true
    def message(%{path: path}), do: "not allowed to access #{path}"
  end

  @hook :ash_quick_route_gate

  @doc false
  def on_mount(:default, params, session, socket), do: on_mount([], params, session, socket)

  def on_mount(opts, _params, _session, socket) when is_list(opts) do
    access_control = access_control!(opts)
    fallback = Keyword.get(opts, :fallback, "/")

    if root_at_router?(socket) do
      {:cont,
       LiveView.attach_hook(socket, @hook, :handle_params, fn _params, uri, socket ->
         gate(socket, URI.parse(uri).path, access_control, fallback)
       end)}
    else
      {:cont, socket}
    end
  end

  # Only the root LiveView of a routed page has a path, and LiveView refuses a
  # `handle_params` hook anywhere else. A nested `live_render` child inherits
  # its parent's router but carries the parent's pid, and a sticky one carries
  # `sticky?`; one rendered from a controller has no router at all.
  defp root_at_router?(%{router: nil}), do: false
  defp root_at_router?(%{parent_pid: parent}) when is_pid(parent), do: false
  defp root_at_router?(%{sticky?: true}), do: false
  defp root_at_router?(_socket), do: true

  @doc """
  True when `scope` may navigate to `path` under `access_control`.

  What the gate asks on every navigation, for a controller or a test that wants
  the same answer. The path is matched with empty segments dropped, as the
  router reads it (`AshQuick.Nav.Info.allowed?/2`).
  """
  def allowed?(access_control, scope, path)
      when is_atom(access_control) and (is_binary(path) or is_nil(path)) do
    Info.allowed?(path, access_control.routes_for(scope))
  end

  defp gate(socket, path, access_control, fallback) do
    scope = socket.assigns[:scope]

    cond do
      allowed?(access_control, scope, path) ->
        {:cont, socket}

      Mount.actor(socket) != nil and not same_path?(path, fallback) ->
        {:halt,
         socket
         |> LiveView.put_flash(
           :error,
           gettext("The person you are acting as can't open %{path}.", path: path)
         )
         |> LiveView.push_navigate(to: fallback)}

      true ->
        raise NotAllowedError, path: path, actor: AshQuick.Scope.actor(scope)
    end
  end

  # Compared as the router reads both, so `fallback: "/dash?tab=1"` or
  # `"/dash/"` is recognised as the page `/dash` and not navigated to again.
  defp same_path?(path, fallback),
    do: Info.normalize_path(path) == Info.normalize_path(URI.parse(fallback).path)

  defp access_control!(opts) do
    case Keyword.get_lazy(opts, :access_control, fn -> Info.access_control(Config.nav()) end) do
      nil ->
        raise ArgumentError, """
        #{inspect(__MODULE__)} has no access control to ask.

        Name one on the nav, `use AshQuick.Nav, access_control: MyAppWeb.AccessControl`, \
        with the nav set as `config :ash_quick, nav: MyAppWeb.Nav`, or pass it to the \
        stage: `{#{inspect(__MODULE__)}, access_control: MyAppWeb.AccessControl}`.
        """

      module ->
        module
    end
  end
end
