defmodule Example.Checks.RoleIsAdminOnly do
  @moduledoc """
  The field-restriction check behind `Example.Accounts.User`'s `:role` field.

  Two things follow from it: the input is left out of the form an editor is
  shown, and `AshQuick.FieldRestrictions.StripRestrictedFields` drops the value
  from their changeset even if one arrives anyway.
  """
  @behaviour AshQuick.FieldRestrictions.Check

  @impl true
  def match?(%{actor: %Example.Accounts.User{role: :admin}}, _opts), do: true
  def match?(_context, _opts), do: false
end
