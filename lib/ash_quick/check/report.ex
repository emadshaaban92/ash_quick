defmodule AshQuick.Check.Report do
  @moduledoc """
  What a run of `mix ash_quick.check` produced: what it found, and what it could
  not look at.

  `skipped` is the half that keeps the report honest. A host that configures no
  nav, or whose access control exports no `all_routes/0`, would otherwise read
  an empty `findings` as a clean bill of health for checks that never ran — the
  exact silence the task exists to break. Each entry is `{check_group, reason}`,
  and `AshQuick.Check.format/1` prints them beside the findings.
  """

  alias AshQuick.Check.Finding

  @type t :: %__MODULE__{findings: [Finding.t()], skipped: [{atom(), String.t()}]}

  defstruct findings: [], skipped: []
end
