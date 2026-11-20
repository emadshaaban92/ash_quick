defmodule AshQuick.AccessControl do
  @moduledoc """
  Behaviour for deciding which routes a given scope can navigate to.

  AshQuick itself has no concept of an application's roles or routing
  rules. Host applications implement this behaviour and name the module on
  their nav, which is what it filters:

      defmodule MyAppWeb.Nav do
        use AshQuick.Nav,
          router: MyAppWeb.Router,
          access_control: MyAppWeb.AccessControl
      end

  AshQuick asks it in two places. The sidebar and the apps grid list only the
  paths the scope may navigate to, and `AshQuick.LiveView.RouteGate`, in the
  live session's `on_mount`, refuses a navigation to any other. Without the
  gate the list hides links and refuses nothing. A nav that names no access
  control lists every entry, and the gate refuses to mount without one.

  ## Why a behaviour and not `Ash.can?`

  The sidebar previously called `Ash.can?({resource, :read}, scope)` to
  decide visibility. Filter policies don't reject an action — they
  attach a filter to the query and let it run, so `Ash.can?` answers
  `true` (the action is allowed; whether any rows come back is only
  known after the query executes). The sidebar therefore showed
  resources the user effectively had no access to. Routing-level
  visibility is a separate concern from row-level filtering and
  belongs in the host app.
  """

  @doc """
  Returns the list of route paths the given scope is allowed to navigate
  to, each a leading-slash string such as `"/products"`.

  A route covers itself and every path under it: `"/products"` covers
  `"/products"` and `"/products/123"`, but not `"/products_archive"`
  (`AshQuick.Nav.Info.allowed?/2`). The scope is `nil` for a visitor nobody
  signed in as, and should get no route.
  """
  @callback routes_for(scope :: any()) :: [String.t()]

  @doc """
  Every path any scope at all could be granted — the union of every list
  `routes_for/1` can return.

  Optional, and read by nothing at request time. `mix ash_quick.check` is its
  only caller: the four reconciliations it runs between the router, the nav and
  this module are all statements about *some role*, and there is no way to
  enumerate roles from here. A module that does not export it simply has those
  checks reported as not run, rather than passing for want of anything to
  compare against.

  Derive it from wherever the roles are declared rather than restating the
  paths, or the list goes stale exactly when a role is added:

      def all_routes do
        MyApp.Accounts.User
        |> Ash.Resource.Info.attribute(:role)
        |> Map.fetch!(:constraints)
        |> Keyword.fetch!(:one_of)
        |> Enum.flat_map(&routes_for_role/1)
        |> Enum.concat(@common_authed_routes)
        |> Enum.uniq()
      end
  """
  @callback all_routes() :: [String.t()]

  @optional_callbacks all_routes: 0
end
