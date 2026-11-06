defmodule AshQuick.RtlIconsTest do
  @moduledoc """
  An icon that points left or right turns around in a right-to-left language.

  "Back" points toward where the reader came from, and a pager's previous and
  next point toward the page they lead to: the start and end of a line, not
  its left and right. Under `dir="rtl"` those swap sides, so every such icon
  carries `rtl:rotate-180`. An icon whose direction means something on screen
  rather than in the text, as an external link's top-right arrow, is not
  matched here.
  """
  use ExUnit.Case, async: true

  @directional ~r/name="hero-(?:arrow|chevron)(?:-(?:long|small|uturn|double))?-(?:left|right)(?:-(?:mini|micro|solid))?"/

  @files ["lib/ash_quick.ex"] ++ Path.wildcard("lib/ash_quick/**/*.{ex,exs,heex}")

  test "every left or right icon mirrors under dir=rtl" do
    offenders =
      for file <- @files,
          {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          Regex.match?(@directional, line),
          not String.contains?(line, "rtl:rotate-180"),
          do: "#{file}:#{number}: #{String.trim(line)}"

    assert offenders == [], """
    These icons keep their left-to-right direction under dir="rtl". Add
    `rtl:rotate-180` to their class:

    #{Enum.join(offenders, "\n")}
    """
  end

  test "the pattern finds the icons it guards" do
    # A pattern that matched nothing would pass the test above forever.
    matched =
      for file <- @files,
          line <- file |> File.read!() |> String.split("\n"),
          Regex.match?(@directional, line),
          do: line

    assert length(matched) >= 7
  end
end
