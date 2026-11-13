defmodule AshQuick.LiveView.BrowserSessionsLiveTest do
  @moduledoc """
  Whose tabs the Live Users register shows, over an actor resource with
  attribute multitenancy and a role-only `:impersonate` policy.

  The view itself needs an endpoint and a running register, which the library
  has neither of, so this pins the narrowing it renders from:
  `BrowserSessionsLive.visible/3`, given the register's sessions, the actor
  resource and the viewer's scope. The example drives the page itself.
  """
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.BrowserSessionsLive
  alias AshQuick.Test.BrowserSessions.Person
  alias AshQuick.Test.Scopes.FullScope

  setup do
    org = "org-#{System.unique_integer([:positive])}"
    other = "#{org}-other"

    admin = person(org, :tenant_admin)
    colleague = person(org, :member)
    stranger = person(other, :member)

    %{org: org, admin: admin, colleague: colleague, stranger: stranger}
  end

  test "a tenant admin passes the gate whichever tenant a session runs in", ctx do
    # The premise: a role check needs no record, so asking with nobody named and
    # no tenant says yes. Without narrowing, this admin would see every tab.
    assert Ash.can?({Person, :impersonate}, scope(ctx.admin, ctx.org), tenant: nil)
  end

  test "a tenant admin sees their own tenant's tabs and not another's", ctx do
    sessions = [
      tab(ctx.colleague),
      tab(ctx.stranger),
      tab(ctx.admin)
    ]

    visible = BrowserSessionsLive.visible(sessions, Person, scope(ctx.admin, ctx.org))

    assert ids(visible) == ids([tab(ctx.colleague), tab(ctx.admin)])
  end

  test "an impersonating tab shows only when both people on it are readable", ctx do
    # Somebody in the other tenant standing in for a colleague, and the
    # colleague standing in for the stranger: either way one of the two people
    # is outside this admin's tenant.
    sessions = [
      tab(ctx.stranger, acting_as: ctx.colleague),
      tab(ctx.colleague, acting_as: ctx.stranger),
      tab(ctx.admin, acting_as: ctx.colleague)
    ]

    visible = BrowserSessionsLive.visible(sessions, Person, scope(ctx.admin, ctx.org))

    assert ids(visible) == ids([tab(ctx.admin, acting_as: ctx.colleague)])
  end

  test "a viewer with no tenant sees nothing on a resource that is not global?", ctx do
    sessions = [tab(ctx.colleague), tab(ctx.stranger)]

    assert BrowserSessionsLive.visible(sessions, Person, scope(ctx.admin, nil)) == []
  end

  defp person(org, role) do
    Person
    |> Ash.Changeset.for_create(:create, %{org: org, role: role}, tenant: org)
    |> Ash.create!(authorize?: false)
  end

  defp scope(actor, tenant), do: %FullScope{user: actor, seller: tenant}

  # The shape `AshQuick.BrowserSessionPresence.sessions/0` reports, with the
  # session id derived from the people on it so two calls name the same tab.
  defp tab(real_actor, opts \\ []) do
    actor = Keyword.get(opts, :acting_as)

    %{
      id: "#{real_actor.id}:#{actor && actor.id}",
      real_actor_id: real_actor.id,
      actor_id: actor && actor.id
    }
  end

  defp ids(sessions), do: sessions |> Enum.map(& &1.id) |> Enum.sort()
end
