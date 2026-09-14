defmodule AshQuick.Check.Finding do
  @moduledoc """
  One divergence `mix ash_quick.check` found.

  `check` names which check found it and `subject` what it is about — a
  resource module, or the path that breaks. Those two are the finding's
  identity: `subject` is what a host exempts a known and accepted divergence by,
  under `check`.

  `message` is the whole of what a reader gets, so it says what will fail and
  how to fix it rather than restating the check's name.

  `severity` is what `--strict` acts on:

    * `:defect` — something is broken. A control leads to a route that is not
      there, a page raises on the first link it builds, a resource's updates
      arrive on another one's topic. This fails the build.
    * `:advisory` — nothing is broken; the application has not finished adopting
      something. Reported every run and never counted, because a number you
      watch go down must not be a number that blocks a deploy.
  """

  @type severity :: :defect | :advisory
  @type t :: %__MODULE__{
          check: atom(),
          subject: term(),
          message: String.t(),
          severity: severity()
        }

  @enforce_keys [:check, :subject, :message]
  defstruct [:check, :subject, :message, severity: :defect]
end
