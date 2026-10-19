defmodule AshQuick.ConfigFormatFallbackTest do
  @moduledoc """
  How `AshQuick.Config` formats dates and times for a host without the
  optional `localize` dependency.

  This suite loads Localize, so the fallback can't run in it. Each case runs
  in a fresh VM that has only AshQuick's own modules on its code path, which
  is what a host without Localize has for this code.
  """
  use ExUnit.Case, async: true

  for {label, call, formatted} <- [
        {"a date", "format_date(~D[2026-03-04])", "2026-03-04"},
        {"a datetime", "format_datetime(~U[2026-03-04 05:06:07Z])", "2026-03-04 05:06:07"},
        {"a naive datetime", "format_datetime(~N[2026-03-04 05:06:07])", "2026-03-04 05:06:07"},
        {"a time", "format_time(~T[05:06:07])", "05:06"},
        {"a time at second precision", "format_time(~T[05:06:07], format: :medium)", "05:06:07"}
      ] do
    test "#{label} reads with a full year and its fields apart" do
      assert without_localize(unquote(call)) == unquote(formatted)
    end
  end

  defp without_localize(call) do
    script = """
    false = Code.ensure_loaded?(Localize)
    IO.write(AshQuick.Config.#{call})
    """

    {output, 0} =
      System.cmd("elixir", ["-pa", Application.app_dir(:ash_quick, "ebin"), "-e", script],
        stderr_to_stdout: true
      )

    output
  end
end
