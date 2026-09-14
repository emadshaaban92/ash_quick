defmodule Example.Accounts.Preparations.AuditLogsSearch do
  @moduledoc """
  The `:search` argument of `Example.Accounts.AuditLog`'s lookup action.

  Both searchable columns hold atoms, so the match is over their text
  representation rather than over the value as stored.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    case Ash.Query.get_argument(query, :search) do
      nil ->
        query

      search ->
        Ash.Query.filter(
          query,
          fragment("?::text ilike ?", resource_name, ^"%#{search}%") or
            fragment("?::text ilike ?", action_name, ^"%#{search}%")
        )
    end
  end
end
