defmodule AshQuick.CheckGatesConfigTest do
  @moduledoc """
  The host's own route gates read from `config :ash_quick, check: [gates: ...]`
  when `AshQuick.Check.run/1` is not handed them, the way `mix ash_quick.check`
  runs it.
  """
  # Not async: this sets `:ash_quick`'s `:check` app env, which is global.
  use ExUnit.Case, async: false

  alias AshQuick.Check
  alias AshQuick.Test.Check.HostGate

  setup do
    original = Application.fetch_env(:ash_quick, :check)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:ash_quick, :check, value)
        :error -> Application.delete_env(:ash_quick, :check)
      end
    end)
  end

  test "a gate named in the configuration gates the QuickViews its sessions serve" do
    assert "/host_gated" in ungated()

    Application.put_env(:ash_quick, :check, gates: [{HostGate, :require_user}])

    refute "/host_gated" in ungated()
    assert "/host_gated_bare" in ungated()
  end

  defp ungated do
    report =
      Check.run(
        domains: [AshQuick.Test.Check.Domain],
        nav: AshQuick.Test.Check.Nav,
        actor_resource: AshQuick.Test.Check.Twin,
        exempt: [],
        tower_reporters: []
      )

    for %{check: :ungated_quick_view, subject: subject} <- report.findings, do: subject
  end
end
