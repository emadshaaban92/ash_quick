defmodule Mix.Tasks.AshQuick.Check do
  @shortdoc "Reports where this application diverges from AshQuick's conventions"

  @moduledoc """
  Reports where this application diverges from the conventions AshQuick is built
  on — a resource that never took the extension on, a QuickView someone routed
  by hand, a granted route with no link leading to it.

      mix ash_quick.check
      mix ash_quick.check --strict

  Without `--strict` it reports and exits 0, so an existing application can
  adopt AshQuick incrementally and watch the number go down. With it, any
  **defect** fails the build — for a project that has reached zero and intends
  to stay there.

  Advisory findings never fail, whichever way it is run. They are adoption
  progress rather than breakage, and a number a project watches go down must not
  be a number that blocks a deploy.

  `AshQuick.Check` documents every check, and how to record a divergence the
  application has decided to keep.
  """

  use Mix.Task

  alias AshQuick.Check

  # The resources, the router and the nav are all read by introspection, so the
  # application has to be compiled and its configuration loaded — but not
  # started: nothing here opens a connection or a socket, and a check that
  # needed a database would not run in the CI job it is meant for.
  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: [strict: :boolean])

    report = Check.run(otp_app: Mix.Project.config()[:app])

    Mix.shell().info(Check.format(report))

    if opts[:strict], do: report |> Check.defects() |> fail_on_defects()
  end

  defp fail_on_defects([]), do: :ok

  defp fail_on_defects(defects) do
    Mix.raise("mix ash_quick.check --strict: #{length(defects)} defect(s)")
  end
end
