defmodule AshQuick.CheckTowerConfigTest do
  @moduledoc """
  The error-reporting check reading Tower's configuration the way
  `mix ash_quick.check` finds it: config loaded, nothing started, and `:tower`
  possibly not loaded at all — so its default is not in the app env yet.

  `AshQuick.CheckTest` passes the reporters in; this is the path that reads
  them.
  """
  # Not async: these stop and unload `:tower` and set its app env, which is
  # global. An async test reporting through Tower in that window would find no
  # reporters configured and raise. `on_exit` puts the default back and starts
  # Tower again.
  use ExUnit.Case, async: false

  alias AshQuick.Check

  setup do
    on_exit(fn ->
      Application.stop(:tower)
      Application.unload(:tower)
      Application.delete_env(:tower, :reporters, persistent: true)
      {:ok, _started} = Application.ensure_all_started(:tower)
    end)
  end

  test "Tower's own default is reported when :tower has not been loaded" do
    unload_tower()

    assert [%{subject: :tower}] = run()
  end

  # The host's config is applied before Tower's `.app` is read, and loading it
  # must not put the default back over it.
  test "a host's empty list survives :tower being loaded after it" do
    unload_tower()
    Application.put_env(:tower, :reporters, [], persistent: true)

    assert run() == []
  end

  test "reads what is configured when :tower is already running" do
    assert [%{subject: :tower}] = run()

    Application.put_env(:tower, :reporters, [], persistent: true)

    assert run() == []
  end

  defp unload_tower do
    :ok = Application.stop(:tower)
    :ok = Application.unload(:tower)

    refute List.keymember?(Application.loaded_applications(), :tower, 0)
    assert Application.get_env(:tower, :reporters) == nil
  end

  defp run do
    Check.run(domains: [], nav: nil, exempt: []).findings
  end
end
