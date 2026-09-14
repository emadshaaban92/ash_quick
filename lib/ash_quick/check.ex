defmodule AshQuick.Check do
  @moduledoc """
  Reports where an application diverges from the conventions AshQuick is built
  on. The engine behind `mix ash_quick.check`.

  AshQuick's verifiers refuse to compile a resource that would fail at request
  time, but every one of them runs *over a resource that took the extension on*
  — so the resource most likely to be non-compliant, the one that never added
  it, is invisible to all of them. The same is true of the router: `quick_view/3`
  cannot see the `live/3` written next to it, and no verifier can hold a nav to
  an access control it was never told about.

  This is the rest of it, run as a task rather than at compile time because none
  of it is the library's to refuse. Turning versioning off is allowed; listing a
  resource no page reaches is allowed; a route with no tile is allowed. Reported,
  each becomes a number a project can watch go down.

  ## Running it

      mix ash_quick.check           # report, exit 0
      mix ash_quick.check --strict  # report, exit 1 if anything was found

  The default is advisory on purpose: an existing application adopts AshQuick
  incrementally, and a check that demands a big-bang conversion to say anything
  at all does not get run. `--strict` is for a project that has reached zero and
  intends to stay there.

  ## What it checks

  Over the resources in the application's domains:

    * `:missing_extension` — a resource carrying no `AshQuick` extension.
    * `:unversioned` — versioning turned off with no `reason`.
    * `:unaudited` — auditing turned off with no `reason`.
    * `:unsearchable` — no usable lookup action, which every list page and
      relationship dropdown needs before it can point here.

  Over the router:

    * `:hand_routed_quick_view` — a QuickView declared with a plain `live/3`,
      so it has no base path to read and raises on the first link it builds.
    * `:mislabelled_route` — `ash_quick` route metadata on a view that is not a
      QuickView, which puts it in the nav as one.
    * `:stray_base_path` — a route served outside the base path it carries.
    * `:unroutable_action` — an update or destroy taking inputs on a QuickView
      with no `/:id/:action` route, so its button patches to a 404 as soon as
      the action's policies allow the button to render.

  Over the nav, the router and the access control together:

    * `:unrouted_nav_path` — a nav path the router does not serve.
    * `:unrouted_grant` — a granted route the router does not serve.
    * `:linkless_route` — a granted route no nav entry renders.
    * `:tileless_route` — a granted route in no group, so no tile.
    * `:unreachable_entry` — a nav entry no role can reach.

  The last four need the set of routes *some* role holds, which only the host
  can enumerate. They run against an access control exporting the optional
  `AshQuick.AccessControl.all_routes/0`, and are reported in `skipped` rather
  than passing silently when it does not.

  ## Accepting a divergence

  A finding stops being reported when the resource states its reason — see the
  `reason` option on the `versioning` and `audit` sections. Where there is
  nowhere to say it, name the subject under its check:

      config :ash_quick,
        check: [
          exempt: [
            # The apps grid is the home page; a tile leading back to it says
            # nothing.
            tileless_route: ["/"],
            # A join resource, which no page lists and no dropdown offers.
            unsearchable: [MyApp.Catalog.ProductTag]
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
      "## #{check} (#{length(findings)})\n",
      Enum.map(findings, &(indent(&1.message) <> "\n"))
    ]
  end

  defp format_skipped([]), do: []

  defp format_skipped(skipped) do
    ["## not checked\n", Enum.map(skipped, fn {_group, reason} -> indent(reason) <> "\n" end)]
  end

  defp summary(%Report{findings: []}), do: "No findings."

  defp summary(%Report{findings: findings}) do
    "#{length(findings)} finding(s) across #{findings |> Enum.uniq_by(& &1.check) |> length()} check(s)."
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
end
