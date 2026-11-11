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

  test "starts the register of signed-in tabs under AshQuick's own supervisor" do
    start_supervised!({AshQuick, pubsub_server: AshQuick.SupervisorTest.PubSub})

    assert [{AshQuick.BrowserSessionPresence, _pid, :supervisor, _modules}] =
             Supervisor.which_children(AshQuick.Supervisor)

    assert AshQuick.BrowserSessionPresence.sessions() == []
  end

  test "refuses an option it does not take" do
    assert_raise ArgumentError, ~r/pubsub/, fn -> AshQuick.child_spec(pubsub: Some.PubSub) end
  end

  test "is a supervisor child the host names once" do
    assert %{id: AshQuick, type: :supervisor} = Supervisor.child_spec(AshQuick, [])
  end
end
