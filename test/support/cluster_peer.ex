defmodule AshQuick.Test.ClusterPeer do
  @moduledoc """
  A second node for the tests that are about what crosses between nodes.

  `:peer` runs it with this node's code path, so the library and this module
  are loadable there. Control runs over standard IO rather than distribution,
  so a test can disconnect the two nodes, the way a netsplit does, and keep
  driving the peer. Neither node connects to the other on its own, so the two
  stay apart until the test connects them.
  """

  @doc """
  Makes this node distributed, starting `epmd` first if nothing runs it.
  Returns `:ok`, or `{:error, reason}` when the machine cannot.
  """
  def ensure_distributed do
    if Node.alive?() do
      :ok
    else
      System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)
      # Only explicit connects, on both nodes. Otherwise a message still in
      # flight to a node just disconnected reconnects the two on its own, and
      # a test of a netsplit is not testing one.
      Application.put_env(:kernel, :dist_auto_connect, :never)

      case Node.start(
             :"ash_quick_test_#{System.unique_integer([:positive])}@127.0.0.1",
             :longnames
           ) do
        {:ok, _pid} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Starts a peer node and connects it. Answers `{peer, node}`."
  def start do
    args =
      [~c"-kernel", ~c"dist_auto_connect", ~c"never"] ++
        Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    {:ok, peer, node} =
      :peer.start(%{
        name: :peer.random_name(),
        host: ~c"127.0.0.1",
        longnames: true,
        args: args,
        connection: :standard_io
      })

    true = Node.connect(node)
    {peer, node}
  end

  @doc """
  Runs on the peer: starts a PubSub server named `pubsub` and
  `AshQuick.Impersonation.Revocations` on it, under a supervisor not linked to
  the caller, which is a short-lived process there.
  """
  def start_revocations(pubsub) do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    {:ok, sup} =
      Supervisor.start_link(
        [
          {Phoenix.PubSub, name: pubsub},
          {AshQuick.Impersonation.Revocations, pubsub_server: pubsub}
        ],
        strategy: :rest_for_one
      )

    Process.unlink(sup)
    :ok
  end
end
