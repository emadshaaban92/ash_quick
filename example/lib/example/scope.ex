defmodule Example.Scope do
  @moduledoc """
  The scope every action in this application runs under.

  `use AshQuick.Scope` generates both `Ash.Scope.ToOpts` and
  `AshQuick.Scope.ToProvenance` from the field names below, so the real actor
  and the request address reach audit rows and the storage seam through the
  library rather than through a convention each reader reproduces. Read them
  back with `AshQuick.Scope.real_actor/1` and friends, off a scope or off a
  changeset.

  `:tenant` is the actor's own store. `Ash.Scope.ToOpts` puts it on every action
  the scope is passed to, so `Example.Catalog.Product`'s `multitenancy` block
  filters without any page mentioning a store. It is nullable, and nullable is
  meaningful: platform staff belong to no store and read every store's
  catalogue, which is what `global? true` on that resource is for.

  `:locale` is the actor's own, read back by `AshQuick.Scope.locale/1` with
  `AshQuick.Config.locale/0` behind it. `ExampleWeb.UserAuth` is what puts it on
  the process and tells the browser about it; nothing in a resource has to know.
  """

  use AshQuick.Scope,
    actor: :current_user,
    real_actor: :real_user,
    impersonating?: :impersonating_mode,
    ip: :ip,
    locale: :locale,
    tenant: :tenant

  defstruct [:current_user, :real_user, :ip, :locale, :tenant, impersonating_mode: false]

  @doc """
  Builds the scope an action runs under.

  `:impersonating` is the user the actor is currently standing in for, and only
  the web layer ever passes it — it comes from the browser tab
  (`AshQuick.Impersonation.Token`), which is why an admin impersonating in one
  tab is still themselves in another.
  """
  def new(opts \\ []) do
    {current_user, real_user, impersonating_mode} =
      resolve_actor(Keyword.get(opts, :actor), Keyword.get(opts, :impersonating))

    %__MODULE__{
      current_user: current_user,
      real_user: real_user,
      impersonating_mode: impersonating_mode,
      ip: Keyword.get(opts, :ip),
      # Both read off whoever the tab is *acting as*, not whoever is at it. An
      # admin standing in for a shopkeeper sees that shop's catalogue in that
      # shopkeeper's language, which is the point of standing in for them.
      locale: locale(current_user),
      tenant: tenant(current_user)
    }
  end

  defp locale(%{locale: locale}), do: to_string(locale)
  defp locale(_no_actor), do: nil

  defp tenant(%{store_id: store_id}), do: store_id
  defp tenant(_no_actor), do: nil

  defp resolve_actor(nil, _impersonating), do: {nil, nil, false}
  defp resolve_actor(user, nil), do: {user, user, false}
  defp resolve_actor(real_user, impersonated), do: {impersonated, real_user, true}
end
