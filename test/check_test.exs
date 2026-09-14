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
  alias AshQuick.Test.Check.Silent

  defp run(opts \\ []) do
    Check.run(Keyword.merge([domains: [Domain], nav: Nav, exempt: []], opts))
  end

  defp found(%Report{findings: findings}), do: Enum.map(findings, &{&1.check, &1.subject})

  describe "what the check finds" do
    test "every check fires, and names what it is about" do
      assert found(run()) == [
               {:missing_extension, AshQuick.Test.Check.Bare},
               {:unversioned, Silent},
               {:unaudited, Silent},
               {:unsearchable, Silent},
               {:hand_routed_quick_view, "/hand_routed"},
               {:mislabelled_route, "/plain"},
               {:stray_base_path, "/elsewhere"},
               {:unroutable_action, "/widgets/:id/rename"},
               {:unrouted_nav_path, "/missing"},
               {:unrouted_grant, "/gone"},
               {:linkless_route, "/orphan"},
               {:tileless_route, "/plain"},
               {:tileless_route, "/orphan"},
               {:unreachable_entry, "/missing"}
             ]
    end

    # `AshQuick.Test.Check.Stated` turns both off exactly as `Silent` does, and
    # differs only in saying why — so its absence above is the whole assertion.
    test "a stated reason is what separates an opt-out from a finding" do
      subjects = run() |> found() |> Keyword.values()

      refute AshQuick.Test.Check.Stated in subjects
      assert Silent in subjects
    end

    # A dead grant has no entry and no group either. Reporting all three would
    # bury the one fact that explains them.
    test "a grant the router does not serve is reported once, as itself" do
      for {check, subject} <- found(run()), subject == "/gone" do
        assert check == :unrouted_grant
      end
    end

    test "nothing is found when there is nothing to check" do
      assert %Report{findings: []} = Check.run(domains: [], nav: nil, exempt: [])
    end
  end

  describe "exemptions" do
    test "drop a finding matched on both its check and its subject" do
      exempt = [tileless_route: ["/orphan"], unversioned: [Silent]]

      found = found(run(exempt: exempt))

      refute {:tileless_route, "/orphan"} in found
      refute {:unversioned, Silent} in found

      # And only those: the same subject under another check still reports.
      assert {:linkless_route, "/orphan"} in found
      assert {:unaudited, Silent} in found
    end

    test "naming a subject under the wrong check exempts nothing" do
      assert {:tileless_route, "/orphan"} in found(run(exempt: [linkless_route: ["/orphan"]]))
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
      refute {:tileless_route, "/plain"} in found(report)
    end

    test "no domains to read resources from" do
      report = run(domains: [])

      assert {:resources, reason} = List.keyfind(report.skipped, :resources, 0)
      assert reason =~ "no domains"
      assert found(report) |> Keyword.keys() |> Enum.uniq() == ~w(
               hand_routed_quick_view mislabelled_route stray_base_path unroutable_action
               unrouted_nav_path unrouted_grant linkless_route tileless_route unreachable_entry
             )a
    end

    test "an access control the nav declares is used when it can enumerate" do
      assert %Report{skipped: []} = run(access_control: AccessControl)
    end
  end

  describe "format/1" do
    test "groups by check, in a stable order, and carries each message whole" do
      text = run() |> Check.format()

      assert text =~ "## missing_extension (1)"
      assert text =~ "## tileless_route (2)"
      assert text =~ "AshQuick.Test.Check.Bare does not carry the AshQuick extension."
      assert text =~ "14 finding(s) across 13 check(s)."

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
