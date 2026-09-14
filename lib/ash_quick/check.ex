defmodule AshQuick.Check do
  @moduledoc """
  Reports where an application diverges from the conventions AshQuick is built
  on. The engine behind `mix ash_quick.check`.

  A Spark verifier sees one resource's DSL and refuses to compile it when
  something would fail at request time. Two kinds of mistake are outside that by
  construction, and they are the whole of what is here: a fact spanning *two*
  resources, and anything at all about the router — `quick_view/3` cannot see
  the `live/3` written next to it, and nothing at compile time holds a nav to an
  access control it was never told about.

  What is deliberately absent is a check over a decision a resource has already
  stated. `versioning enabled? false` is the statement; asking for a sentence
  beside it would be work that catches nothing, which is how a check ends up
  ignored.

  ## Running it

      mix ash_quick.check           # report, exit 0
      mix ash_quick.check --strict  # report, exit 1 on any defect

  Reporting without failing is the default on purpose: an existing application
  adopts AshQuick incrementally, and a check that demands a big-bang conversion
  to say anything at all does not get run. `--strict` is for a project that has
  reached zero and intends to stay there.

  ## What it checks

  Over the resources in the application's domains:

    * `:colliding_liveness_prefix` — two resources publishing on one topic, so
      each one's writes reach the other's pages. Structurally invisible to a
      resource verifier, which only ever sees one of them.
    * `:missing_extension` — a resource carrying no `AshQuick` extension.
      **Advisory**: nothing is broken, the adoption is unfinished.

  Over the router:

    * `:hand_routed_quick_view` — a QuickView declared with a plain `live/3`,
      so it has no base path to read and raises on the first link it builds.
    * `:mislabelled_route` — `ash_quick` route metadata on a view that is not a
      QuickView, which puts it in the nav as one.
    * `:stray_base_path` — a route served outside the base path it carries.
    * `:unroutable_show`, `:unroutable_action` — a control the page renders
      leading to a route `:only` or `:except` left out. Rows link to
      `<base>/<id>` and a create redirects there; an action taking inputs
      patches to `<base>/<id>/<action>` rather than running inline. Neither can
      be fixed by hiding one control, so both are reported. (The New button
      *is* gated on its route — see `AshQuick.LiveView.Router.served_shapes/2`
      — so there is nothing to report there.)

  Over the nav, the router and the access control together:

    * `:unrouted_nav_path` — a nav path the router does not serve.
    * `:unrouted_grant` — a granted route the router does not serve.
    * `:linkless_route` — a granted route no nav entry renders.
    * `:unreachable_entry` — a nav entry no role can reach.

  The last three need the set of routes *some* role holds, which only the host
  can enumerate. They run against an access control exporting the optional
  `AshQuick.AccessControl.all_routes/0`, and are reported in `skipped` rather
  than passing silently when it does not.

  ## Advisory findings

  `--strict` fails on defects and ignores advisories. A number a project watches
  go down must not be a number that blocks a deploy, so `:missing_extension`
  reports on every run and counts towards nothing.

  ## Accepting a divergence

  Name the subject under its check:

      config :ash_quick,
        check: [
          exempt: [
            # Taken by the upload pipeline and forbidden to everyone else, so
            # the button this warns about cannot render.
            unroutable_action: ["/file_objects/:id/reference"]
          ]
        ]

  Exempting is a decision to keep the divergence, so it belongs in the
  application's configuration where it can be read back, rather than in a flag
  on the command that would make it invisible.
  """

  alias AshQuick.Check.Finding
  alias AshQuick.Check.Nav
  alias AshQuick.Check.Report
  alias AshQuick.Check.Resources
  alias AshQuick.Check.Routing
  alias AshQuick.Nav.Info

  @doc """
  Runs every check and returns an `AshQuick.Check.Report`.

  ## Options

    * `:domains` — the domains whose resources are read. Defaults to the ones
      `:otp_app` registers.
    * `:otp_app` — the application to read `:ash_domains` from. Without either,
      the resource checks are reported as not run.
    * `:nav` — the nav module. Defaults to the configured one.
    * `:router` — defaults to the router the nav declares.
    * `:access_control` — defaults to the one the nav declares.
    * `:exempt` — `[check_name: [subject]]`. Defaults to the configured
      `:check, :exempt`.
  """
  @spec run(keyword()) :: Report.t()
  def run(opts \\ []) do
    nav = Keyword.get_lazy(opts, :nav, &AshQuick.Config.nav/0)
    router = Keyword.get_lazy(opts, :router, fn -> Info.router(nav) end)
    access_control = Keyword.get_lazy(opts, :access_control, fn -> Info.access_control(nav) end)

    [
      Resources.run(domains(opts)),
      Routing.run(router),
      Nav.run(nav, router, access_control)
    ]
    |> Enum.reduce(%Report{}, fn {findings, skipped}, report ->
      %Report{
        findings: report.findings ++ findings,
        skipped: report.skipped ++ skipped
      }
    end)
    |> exempt(Keyword.get_lazy(opts, :exempt, &AshQuick.Config.check_exemptions/0))
  end

  @doc """
  The report as the text `mix ash_quick.check` prints, findings grouped by
  check.
  """
  @spec format(Report.t()) :: String.t()
  def format(%Report{} = report) do
    [
      report.findings |> Enum.group_by(& &1.check) |> Enum.sort() |> Enum.map(&format_check/1),
      format_skipped(report.skipped),
      summary(report)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp format_check({check, findings}) do
    [
      "## #{check} (#{length(findings)})#{advisory_note(findings)}\n",
      Enum.map(findings, &(indent(&1.message) <> "\n"))
    ]
  end

  defp advisory_note([%Finding{severity: :advisory} | _]), do: " — advisory, not counted"
  defp advisory_note(_findings), do: ""

  defp format_skipped([]), do: []

  defp format_skipped(skipped) do
    ["## not checked\n", Enum.map(skipped, fn {_group, reason} -> indent(reason) <> "\n" end)]
  end

  defp summary(%Report{findings: []}), do: "No findings."

  defp summary(%Report{findings: findings}) do
    case length(findings) - length(defects(findings)) do
      0 -> "#{length(findings)} defect(s)."
      advisory -> "#{length(findings) - advisory} defect(s), #{advisory} advisory."
    end
  end

  defp indent(message) do
    message
    |> String.trim_trailing()
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> "  " <> line
    end)
  end

  defp domains(opts) do
    cond do
      domains = opts[:domains] -> domains
      otp_app = opts[:otp_app] -> Ash.Info.domains(otp_app)
      true -> []
    end
  end

  defp exempt(%Report{} = report, exemptions) do
    %{report | findings: Enum.reject(report.findings, &exempt?(&1, exemptions))}
  end

  defp exempt?(%Finding{check: check, subject: subject}, exemptions) do
    subject in Keyword.get(exemptions, check, [])
  end

  @doc """
  The findings `--strict` fails on: everything but the advisories.
  """
  @spec defects(Report.t() | [Finding.t()]) :: [Finding.t()]
  def defects(%Report{findings: findings}), do: defects(findings)

  def defects(findings) when is_list(findings),
    do: Enum.filter(findings, &(&1.severity != :advisory))
end
