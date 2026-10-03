defmodule AshQuick.CheckTest do
  @moduledoc """
  The compliance check against a fixture application built to fail every one of
  its checks at once.

  Asserted as the whole set rather than one test per check, because the set is
  the claim: a check that silently stops firing is the failure this task exists
  to prevent, and only comparing the lot catches one going missing.
  """
  use ExUnit.Case, async: true

  alias AshQuick.Check
  alias AshQuick.Check.Report
  alias AshQuick.Test.Check.AccessControl
  alias AshQuick.Test.Check.Domain
  alias AshQuick.Test.Check.Nav

  # Tower's reporters are passed in rather than read, so this module never
  # touches the `:tower` app env; `AshQuick.CheckTowerConfigTest` reads it.
  defp run(opts \\ []) do
    Check.run(
      Keyword.merge(
        [domains: [Domain], nav: Nav, exempt: [], tower_reporters: [Tower.EphemeralReporter]],
        opts
      )
    )
  end

  defp found(%Report{findings: findings}), do: Enum.map(findings, &{&1.check, &1.subject})

  defp only_tower(%Report{findings: findings}),
    do: Enum.filter(findings, &(&1.check == :unconfigured_error_reporter))

  describe "what the check finds" do
    test "every check fires, and names what it is about" do
      assert found(run()) == [
               {:missing_extension, AshQuick.Test.Check.Bare},
               {:colliding_liveness_prefix, "signal"},
               {:hand_routed_quick_view, "/hand_routed"},
               {:mislabelled_route, "/plain"},
               {:stray_base_path, "/elsewhere"},
               {:unroutable_action, "/widgets/:id/rename"},
               {:unroutable_show, "/gizmos/:id"},
               {:unrouted_nav_path, "/missing"},
               {:unrouted_grant, "/gone"},
               {:linkless_route, "/orphan"},
               {:unreachable_entry, "/missing"},
               {:unreachable_entry, "/gizmos"},
               {:unconfigured_error_reporter, :tower}
             ]
    end

    # The three that were dropped for asking a resource to justify a decision it
    # had already stated, or to hold a convention the library argues against.
    test "no check reports a stated opt-out or a missing lookup action" do
      checks = run() |> found() |> Keyword.keys() |> Enum.uniq()

      refute :unversioned in checks
      refute :unaudited in checks
      refute :unsearchable in checks
      refute :tileless_route in checks
    end

    # A resource that publishes nothing collides with nothing, so the check has
    # to turn on `enabled?` rather than on the prefix alone.
    test "a prefix collision names every resource sharing the topic" do
      assert [collision] =
               run().findings |> Enum.filter(&(&1.check == :colliding_liveness_prefix))

      assert collision.message =~ "AshQuick.Test.Check.Echo"
      assert collision.message =~ "AshQuick.Test.Check.Repeat"
      refute collision.message =~ "AshQuick.Test.Check.Widget"
    end

    # `AshQuick.Test.Check.Bare` is the only advisory, and `--strict` reads
    # `defects/1` rather than the whole list.
    test "an unadopted resource is advisory, and does not fail a strict run" do
      report = run()

      assert [%{check: :missing_extension, severity: :advisory}] =
               Enum.filter(report.findings, &(&1.severity == :advisory))

      refute {:missing_extension, AshQuick.Test.Check.Bare} in Enum.map(
               Check.defects(report),
               &{&1.check, &1.subject}
             )
    end

    # A dead grant has no entry either. Reporting both would bury the one fact
    # that explains them.
    test "a grant the router does not serve is reported once, as itself" do
      for {check, subject} <- found(run()), subject == "/gone" do
        assert check == :unrouted_grant
      end
    end

    test "nothing is found when there is nothing to check" do
      assert %Report{findings: []} =
               Check.run(domains: [], nav: nil, exempt: [], tower_reporters: [])
    end
  end

  describe "where unexplained errors are reported" do
    # The default delivers nowhere, so the errors a page reduced to a generic
    # sentence are lost — broken, not unfinished, so it counts under --strict.
    test "Tower's default reporter is a defect" do
      assert [finding] = only_tower(run(tower_reporters: [Tower.EphemeralReporter]))

      assert %{subject: :tower, severity: :defect} = finding
      assert finding.message =~ "config :tower, reporters: ["
      assert finding in Check.defects(run())
    end

    # Nobody writes an empty list by accident; hosts set it in test.
    test "an explicit empty list is a decision, not reported" do
      assert only_tower(run(tower_reporters: [])) == []
    end

    test "any other list is not reported" do
      assert only_tower(run(tower_reporters: [SomeReporter])) == []
      assert only_tower(run(tower_reporters: [Tower.EphemeralReporter, SomeReporter])) == []
    end

    test "is exempted under :tower" do
      assert only_tower(run(exempt: [unconfigured_error_reporter: [:tower]])) == []
    end
  end

  describe "exemptions" do
    test "drop a finding matched on both its check and its subject" do
      found = found(run(exempt: [linkless_route: ["/orphan"], unrouted_grant: ["/gone"]]))

      refute {:linkless_route, "/orphan"} in found
      refute {:unrouted_grant, "/gone"} in found

      # And only those: another subject under the same check still reports.
      assert {:unreachable_entry, "/missing"} in found
    end

    test "naming a subject under the wrong check exempts nothing" do
      assert {:linkless_route, "/orphan"} in found(run(exempt: [unroutable_show: ["/orphan"]]))
    end
  end

  describe "what did not run is reported rather than passing" do
    # The router is the nav's, so losing the nav loses the routing checks too —
    # and both say so rather than one standing in for the other.
    test "a nav that is not configured, and the router that came with it" do
      assert %Report{skipped: skipped} = run(nav: nil)

      assert {:routing, routing} = List.keyfind(skipped, :routing, 0)
      assert routing =~ "no router was given"

      assert {:nav, nav} = List.keyfind(skipped, :nav, 0)
      assert nav =~ "no nav is configured"
    end

    test "an access control that cannot enumerate what it grants" do
      report = run(access_control: AshQuick.Test.Check.SilentAccessControl)

      assert [{:nav, reason}] = report.skipped
      assert reason =~ "exports no `all_routes/0`"

      # The checks that do not depend on a role still run.
      assert {:unrouted_nav_path, "/missing"} in found(report)
      refute {:linkless_route, "/orphan"} in found(report)
    end

    test "no domains to read resources from" do
      report = run(domains: [])

      assert {:resources, reason} = List.keyfind(report.skipped, :resources, 0)
      assert reason =~ "no domains"
      assert found(report) |> Keyword.keys() |> Enum.uniq() == ~w(
               hand_routed_quick_view mislabelled_route stray_base_path unroutable_action
               unroutable_show unrouted_nav_path unrouted_grant linkless_route unreachable_entry
               unconfigured_error_reporter
             )a
    end

    test "an access control the nav declares is used when it can enumerate" do
      assert %Report{skipped: []} = run(access_control: AccessControl)
    end
  end

  describe "format/1" do
    test "groups by check, in a stable order, and carries each message whole" do
      text = run() |> Check.format()

      assert text =~ "## missing_extension (1) — advisory, not counted"
      assert text =~ "## unreachable_entry (2)"
      assert text =~ "AshQuick.Test.Check.Bare does not carry the AshQuick extension."
      assert text =~ "12 defect(s), 1 advisory."

      checks = Regex.scan(~r/^## (\w+)/m, text, capture: :all_but_first) |> List.flatten()
      assert checks == Enum.sort(checks)
    end

    test "says what did not run, beside what did" do
      text = run(nav: nil) |> Check.format()

      assert text =~ "## not checked"
      assert text =~ "no nav is configured"
    end

    test "says so plainly when there is nothing to report" do
      assert Check.format(%Report{}) =~ "No findings."
    end
  end
end
