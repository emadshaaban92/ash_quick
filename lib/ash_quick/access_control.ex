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

  When declared, AshQuick uses the module to filter the sidebar and the apps
  grid so only paths the user can actually navigate to are listed. When not
  declared, no filtering is applied and every entry is shown.

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
  to. Each path is a leading-slash string like `"/products"` that
  matches `"/\#{Ash.Resource.Info.plural_name(resource)}"`.
  """
  @callback routes_for(scope :: any()) :: [String.t()]
end
