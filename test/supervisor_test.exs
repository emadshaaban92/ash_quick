defmodule AshQuick.SupervisorTest do
  @moduledoc """
  The one entry a host's tree names. Both processes register global names, so
  this runs alone.
  """
  use ExUnit.Case, async: false

  setup do
    start_supervised!({Phoenix.PubSub, name: AshQuick.SupervisorTest.PubSub})
    :ok
  end

  test "starts the register of signed-in tabs and the export sweeper under AshQuick's own supervisor" do
    start_supervised!({AshQuick, pubsub_server: AshQuick.SupervisorTest.PubSub})

    children = Supervisor.which_children(AshQuick.Supervisor)

    assert {AshQuick.BrowserSessionPresence, _pid, :supervisor, _modules} =
             List.keyfind(children, AshQuick.BrowserSessionPresence, 0)

    assert {AshQuick.Storage.Sweeper, sweeper, :worker, _modules} =
             List.keyfind(children, AshQuick.Storage.Sweeper, 0)

    assert is_pid(sweeper)
    assert length(children) == 2

    assert AshQuick.BrowserSessionPresence.sessions() == []
  end

  # The suite's storage keeps no exports of its own to expire, which is every
  # storage that leaves `delete_expired/3` out: the sweep is then a no-op.
  test "a sweep over a storage that cannot expire objects deletes nothing" do
    assert AshQuick.Storage.Sweeper.sweep() == {:ok, 0}
  end

  test "refuses an option it does not take" do
    assert_raise ArgumentError, ~r/pubsub/, fn -> AshQuick.child_spec(pubsub: Some.PubSub) end
  end

  test "is a supervisor child the host names once" do
    assert %{id: AshQuick, type: :supervisor} = Supervisor.child_spec(AshQuick, [])
  end
end
