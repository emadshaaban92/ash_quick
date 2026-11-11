defmodule AshQuick.PackageJsonTest do
  @moduledoc """
  `package.json` is what lets a host's `app.js` import AshQuick's client half
  as `ash_quick`, and Hex ships it beside `mix.exs`. Nothing publishes it to
  npm, so it carries no version, only the name and the entry.
  """
  use ExUnit.Case, async: true

  @package "package.json" |> File.read!() |> JSON.decode!()

  test "names the package as hosts import it" do
    assert @package["name"] == "ash_quick"
  end

  test "points at an entry that exists" do
    assert File.exists?(@package["module"])
    assert @package["main"] == @package["module"]
  end
end
