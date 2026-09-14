defmodule ExampleWeb.AccessControl do
  @moduledoc """
  Which UI routes each role may navigate to.

  This is the single source of truth for route access, and it is **not**
  `Ash.can?`: a filter policy allows the action and returns no rows, so `can?`
  says yes for a page that would be empty. The nav renders through it
  (`ExampleWeb.Nav` names it), and `ExampleWeb.UserAuth`'s mount-time gate runs
  `can_access?/2` on every navigation, raising `ExampleWeb.NotAllowedError` for
  a path the role does not hold.

  Each clause lists every route its role unlocks, fully expanded. That is
  deliberate: adding a route means touching every role that should reach it,
  and the catch-all grants nothing, so a role nobody opened up is fail-closed.

  Matching is strict prefix matching — `/products` covers `/products` and
  `/products/123`, but not `/products_archive`.
  """

  @behaviour AshQuick.AccessControl

  alias Example.Accounts.User
  alias Example.Scope

  # Reachable by anyone signed in, whatever their role: the apps grid.
  @common_authed_routes ~w(/)

  @impl AshQuick.AccessControl
  def routes_for(%Scope{current_user: %User{active: true} = user}) do
    Enum.uniq(@common_authed_routes ++ routes_for_role(user.role))
  end

  def routes_for(_scope), do: []

  @doc """
  True when the scope may navigate to `path`.

  Either the path equals an allowed route or it sits directly under one.
  """
  def can_access?(%Scope{} = scope, path) when is_binary(path) do
    scope |> routes_for() |> Enum.any?(&path_matches?(path, &1))
  end

  defp path_matches?(path, route), do: path == route or String.starts_with?(path, route <> "/")

  def routes_for_role(:admin) do
    ~w(/brands /categories /products /price_changes /users /audit_logs /file_objects /browser_sessions)
  end

  def routes_for_role(:editor) do
    ~w(/brands /categories /products /price_changes /file_objects)
  end

  def routes_for_role(:viewer) do
    ~w(/brands /categories /products /price_changes)
  end

  def routes_for_role(_unknown), do: []

  @doc """
  Every route any role at all can reach, for `mix ash_quick.check`.

  Taken from the role list on `Example.Accounts.User` rather than from a copy of
  it here, so a role added there and nowhere else has its routes reconciled too
  — and one added *only* here would grant nothing and be reported as a dead
  entry rather than quietly widening the union.
  """
  @impl AshQuick.AccessControl
  def all_routes do
    User
    |> Ash.Resource.Info.attribute(:role)
    |> Map.fetch!(:constraints)
    |> Keyword.fetch!(:one_of)
    |> Enum.flat_map(&routes_for_role/1)
    |> Enum.concat(@common_authed_routes)
    |> Enum.uniq()
  end
end
