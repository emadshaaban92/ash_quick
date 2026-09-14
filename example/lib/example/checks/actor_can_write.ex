defmodule Example.Checks.ActorCanWrite do
  @moduledoc """
  True when the actor may change catalog data — an admin or an editor.

  A viewer fails it, which is what makes every create/update/destroy control
  disappear from their pages: QuickView renders a button only where
  `AshQuick.can?/4` says the action would be allowed.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is an admin or an editor"

  @impl true
  def match?(%Example.Accounts.User{role: role, active: true}, _context, _opts)
      when role in [:admin, :editor],
      do: true

  def match?(_actor, _context, _opts), do: false
end
