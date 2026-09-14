defmodule AshQuick.Check.Finding do
  @moduledoc """
  One divergence `mix ash_quick.check` found.

  `check` names which check found it and `subject` what it is about — a
  resource module, or the path that breaks. Those two are the finding's
  identity: `subject` is what a host exempts a known and accepted divergence by,
  under `check`.

  `message` is the whole of what a reader gets, so it says what will fail and
  how to fix it rather than restating the check's name.
  """

  @type t :: %__MODULE__{check: atom(), subject: term(), message: String.t()}

  @enforce_keys [:check, :subject, :message]
  defstruct [:check, :subject, :message]
end
