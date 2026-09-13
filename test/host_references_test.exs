defmodule AshQuick.HostReferencesTest do
  @moduledoc """
  Nothing inside AshQuick names an application it happens to be installed in.

  Every reason a comment gives survives with a generic example; a host module
  or extension named in one is a fact about one app, and it stops being true in
  the next. The names below are the ones this library was extracted from —
  a citation that came back would come back from there.
  """
  use ExUnit.Case, async: true

  @host_names ~w(Commerce AshIntegration Halan Cairo)
  @pattern ~r/\b(#{Enum.join(@host_names, "|")})/

  @files ["lib/ash_quick.ex"] ++ Path.wildcard("lib/ash_quick/**/*.{ex,exs,heex}")

  test "no file names a host application" do
    offenders =
      for file <- @files,
          {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          Regex.match?(@pattern, line),
          do: "#{file}:#{number}: #{String.trim(line)}"

    assert offenders == [], """
    AshQuick must not name its host. Rewrite these with a generic example:

    #{Enum.join(offenders, "\n")}
    """
  end
end
