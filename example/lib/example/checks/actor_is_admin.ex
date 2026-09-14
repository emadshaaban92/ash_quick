defmodule Example.Checks.ActorIsAdmin do
  @moduledoc """
  True when the actor holds the `:admin` role.

  A simple check rather than an expression one, so it answers for a
  record-less `Ash.can?/3` — which is what QuickView probes with before it
  decides whether to render a "New" button.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is an admin"

  @impl true
  def match?(%Example.Accounts.User{role: :admin, active: true}, _context, _opts), do: true
  def match?(_actor, _context, _opts), do: false
end
