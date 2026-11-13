defmodule AshQuick.Impersonation.RevocationsClusterTest do
  @moduledoc """
  What two nodes tell each other about ended impersonations: a node that
  joins later learns what was revoked before it, and both sides of a healed
  netsplit learn what the other revoked during it.

  It makes this node distributed and runs a second one, so it runs alone.
  """
  use ExUnit.Case, async: false

  alias AshQuick.Impersonation.Revocations
  alias AshQuick.Test.ClusterPeer

  @pubsub AshQuick.Impersonation.RevocationsClusterTest.PubSub

  setup_all do
    :ok = ClusterPeer.ensure_distributed()
    :ok
  end

  setup do
    start_supervised!({Phoenix.PubSub, name: @pubsub})
    start_supervised!({Revocations, pubsub_server: @pubsub})
    {peer, node} = ClusterPeer.start()
    on_exit(fn -> :peer.stop(peer) end)
    %{peer: peer, node: node}
  end

  test "a node that starts later is handed what was revoked before it", %{peer: peer} do
    Revocations.revoke("before-join", DateTime.utc_now())

    :ok = :peer.call(peer, ClusterPeer, :start_revocations, [@pubsub])

    assert eventually(fn -> revoked_on?(peer, "before-join") end)
  end

  test "both sides of a healed netsplit learn what the other revoked", ctx do
    %{peer: peer, node: node} = ctx
    :ok = :peer.call(peer, ClusterPeer, :start_revocations, [@pubsub])

    true = Node.disconnect(node)
    assert eventually(fn -> node not in Node.list() end)

    Revocations.revoke("here-during-split", DateTime.utc_now())
    :ok = :peer.call(peer, Revocations, :revoke, ["there-during-split", DateTime.utc_now()])

    refute revoked_on?(peer, "here-during-split")
    refute Revocations.revoked?("there-during-split")

    true = Node.connect(node)

    assert eventually(fn -> revoked_on?(peer, "here-during-split") end)
    assert eventually(fn -> Revocations.revoked?("there-during-split") end)
  end

  defp revoked_on?(peer, id), do: :peer.call(peer, Revocations, :revoked?, [id])

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end
end
