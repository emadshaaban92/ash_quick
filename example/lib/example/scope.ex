defmodule Example.Scope do
  @moduledoc """
  The scope every action in this application runs under.

  `use AshQuick.Scope` generates both `Ash.Scope.ToOpts` and
  `AshQuick.Scope.ToProvenance` from the field names below, so the real actor
  and the request address reach audit rows and the storage seam through the
  library rather than through a convention each reader reproduces. Read them
  back with `AshQuick.Scope.real_actor/1` and friends, off a scope or off a
  changeset.

  `:tenant` is deliberately absent: this application is single-tenant, and the
  option exists to be omitted in exactly that case.
  """

  use AshQuick.Scope,
    actor: :current_user,
    real_actor: :real_user,
    impersonating?: :impersonating_mode,
    ip: :ip

  defstruct [:current_user, :real_user, :ip, impersonating_mode: false]

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
      ip: Keyword.get(opts, :ip)
    }
  end

  defp resolve_actor(nil, _impersonating), do: {nil, nil, false}
  defp resolve_actor(user, nil), do: {user, user, false}
  defp resolve_actor(real_user, impersonated), do: {impersonated, real_user, true}
end
