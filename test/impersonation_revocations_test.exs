defmodule AshQuick.Impersonation.RevocationsTest do
  @moduledoc """
  The record of impersonations ended from the console. It registers a global
  name and an ETS table, so this runs alone.
  """
  use ExUnit.Case, async: false

  alias AshQuick.Impersonation.Revocations

  @pubsub AshQuick.Impersonation.RevocationsTest.PubSub

  setup do
    start_supervised!({Phoenix.PubSub, name: @pubsub})
    start_supervised!({Revocations, pubsub_server: @pubsub})
    :ok
  end

  test "an id revoked here is refused here at once" do
    refute Revocations.revoked?("imp-1")
    assert Revocations.revoke("imp-1", DateTime.utc_now()) == :ok
    assert Revocations.revoked?("imp-1")
    refute Revocations.revoked?("imp-2")
  end

  test "anything that is not an id is not revoked" do
    refute Revocations.revoked?(nil)
  end

  test "a revocation is broadcast for every other node to record" do
    :ok = Phoenix.PubSub.subscribe(@pubsub, Revocations.topic())
    Revocations.revoke("imp-3", DateTime.utc_now())
    assert_receive {:revoked, [{"imp-3", _expires_at}]}
  end

  test "one broadcast by another node is recorded here" do
    expires_at = System.system_time(:second) + 60
    Phoenix.PubSub.broadcast(@pubsub, Revocations.topic(), {:revoked, [{"imp-4", expires_at}]})

    # A call queues behind the broadcast, so the table has it once this returns.
    :sys.get_state(Revocations)
    assert Revocations.revoked?("imp-4")
  end

  test "a node that starts later is handed what this one holds" do
    Revocations.revoke("imp-5", DateTime.utc_now())
    send(Revocations, {:sync, self()})
    assert_receive {:revoked, entries}
    assert {"imp-5", _expires_at} = List.keyfind(entries, "imp-5", 0)
  end

  test "an entry outlives its token by a second, so the two never race" do
    # The token is checked to the millisecond and this to the second: at the
    # token's last whole second the entry still stands.
    max_age = AshQuick.Config.impersonation_max_age()
    Revocations.revoke("imp-8", DateTime.add(DateTime.utc_now(), -max_age, :second))
    assert Revocations.revoked?("imp-8")
  end

  test "an impersonation whose token has already expired is not kept" do
    # Kept a second past the token, so this one is a second further back.
    max_age = AshQuick.Config.impersonation_max_age()
    started_at = DateTime.add(DateTime.utc_now(), -(max_age + 1), :second)

    Revocations.revoke("imp-6", started_at)
    refute Revocations.revoked?("imp-6")
    send(Revocations, {:sync, self()})
    assert_receive {:revoked, entries}
    refute List.keyfind(entries, "imp-6", 0)
  end

  test "nothing is revoked when the record is not running" do
    stop_supervised!(Revocations)
    refute Revocations.revoked?("imp-1")
  end
end
