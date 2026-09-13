defmodule AshQuick.Impersonation.NoOp do
  @moduledoc """
  The manual implementation behind the generated impersonation action.

  Starting an impersonation writes nothing: the impersonation itself lives in
  the browser tab that asked for it. Running it through Ash anyway is what
  enforces the resource's policy and records who impersonated whom in the audit
  log, and a manual action gets both without touching the row.
  """

  use Ash.Resource.ManualUpdate

  @impl true
  def update(changeset, _opts, _context), do: {:ok, changeset.data}
end
