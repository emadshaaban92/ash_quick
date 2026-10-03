defmodule AshQuick.Check.ErrorReporting do
  @moduledoc false
  # Where the errors a page could not explain end up.
  #
  # `AshQuick.LiveView.ActionErrors` shows the person a generic sentence and
  # hands the error itself to Tower, so the report is the only trace anyone gets
  # of it. Tower's own default for `:reporters` is `[Tower.EphemeralReporter]`,
  # which keeps the last 50 events in this node's memory and sends them nowhere:
  # a host that never configured Tower loses every one of those errors, and
  # nothing says so. Hence a defect rather than an advisory — it is not
  # unfinished adoption, it is errors going missing.
  #
  # `reporters: []` is not flagged. Nobody writes that by accident, and hosts
  # set it on purpose in test. Any other list is the host's choice too: whether
  # a reporter it names delivers anywhere is beyond what a check can see.

  alias AshQuick.Check.Finding

  @default [Tower.EphemeralReporter]

  def run(@default), do: {[finding()], []}
  def run(_reporters), do: {[], []}

  defp finding do
    %Finding{
      check: :unconfigured_error_reporter,
      subject: :tower,
      message: """
      Tower's `:reporters` is #{inspect(@default)}, its default.

      AshQuick reports every error a page could not explain through Tower, \
      and shows the person a generic sentence instead. The default reporter \
      keeps the last 50 of those in this node's memory and sends them \
      nowhere, so each one is gone at the next restart and nobody hears of \
      it.

      Name a reporter that delivers them — see \
      https://hexdocs.pm/tower/Tower.html#module-reporters:

          config :tower, reporters: [TowerSentry]

      This is the configuration of the environment the check ran in; \
      `reporters: []` there is read as a decision and is not reported.
      """
    }
  end

  # `mix ash_quick.check` loads the application's configuration but starts
  # nothing, so `:tower` may not be loaded yet. Its default lives in its `.app`
  # file, and until that is loaded `get_env/2` answers `nil` rather than the
  # list that will be in force once Tower starts — which would read as
  # configured. Loading keeps what the host's config already set.
  def configured_reporters do
    _loaded_or_already = Application.load(:tower)
    Application.get_env(:tower, :reporters)
  end
end
