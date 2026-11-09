defmodule Example.Checks.RoleIsAdminOnly do
  @moduledoc """
  The `writable_if:` check behind `Example.Accounts.User`'s read-only `:role`
  field: only an admin may write it.

  Two things follow from it: the input is left out of the form an editor is
  shown, and `AshQuick.ReadOnlyFields.StripReadOnlyFields` drops the value from
  their changeset even if one arrives anyway.
  """
  @behaviour AshQuick.ReadOnlyFields.Check

  @impl true
  def match?(%{actor: %Example.Accounts.User{role: :admin}}, _opts), do: true
  def match?(_context, _opts), do: false
end
