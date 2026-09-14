defmodule Mix.Tasks.AshQuick.CheckTest do
  @moduledoc """
  The task itself: what it prints, and what `--strict` does with it.

  `async: false`, and it swaps the configured nav — the task reads the
  application's own configuration, which is the whole point of it, so there is
  nothing to inject and the swap is real global state.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.AshQuick.Check, as: Task

  setup do
    previous = Application.get_env(:ash_quick, :nav)
    Application.put_env(:ash_quick, :nav, AshQuick.Test.Check.Nav)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:ash_quick, :nav)
        nav -> Application.put_env(:ash_quick, :nav, nav)
      end
    end)

    :ok
  end

  test "reports what it found and exits cleanly" do
    output = capture_io(fn -> Task.run([]) end)

    assert output =~ "## hand_routed_quick_view (1)"
    assert output =~ "/hand_routed"
    assert output =~ "finding(s) across"
  end

  test "--strict reports the same thing and then fails the build" do
    assert_raise Mix.Error, ~r/ash_quick.check --strict: \d+ finding/, fn ->
      capture_io(fn -> Task.run(["--strict"]) end)
    end
  end

  test "--strict is silent about success when there is nothing to report" do
    Application.put_env(:ash_quick, :nav, nil)

    output = capture_io(fn -> Task.run(["--strict"]) end)

    assert output =~ "No findings."
  end

  test "refuses an option it does not know rather than ignoring it" do
    assert_raise OptionParser.ParseError, fn ->
      capture_io(fn -> Task.run(["--fix"]) end)
    end
  end
end
