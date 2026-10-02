defmodule AshQuick.ClientIpTest do
  @moduledoc """
  The controller's way in, and the check a host runs on its setting.

  `AshQuick.LiveView.MountTest` covers what each `:client_ip` form reads. This
  covers `from_conn/1` reading the same way off a `Plug.Conn`, and
  `config_violations/1` catching a setting before anything connects.

  `from_conn/1` reads global config, so this module runs alone.
  """
  use ExUnit.Case, async: false

  import Plug.Test

  alias AshQuick.ClientIp
  alias AshQuick.LiveView.Mount

  defmodule IpSource do
    @moduledoc false
    def echo(info, test_pid) do
      send(test_pid, {:client_ip_info, info})
      nil
    end
  end

  setup do
    original = Application.fetch_env(:ash_quick, :client_ip)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:ash_quick, :client_ip, value)
        :error -> Application.delete_env(:ash_quick, :client_ip)
      end
    end)
  end

  defp put_client_ip(value), do: Application.put_env(:ash_quick, :client_ip, value)

  # The peer is 10.0.0.1. `remote_ip` says otherwise, as it would after a plug
  # rewrote it, to show that it is not what is read.
  defp request(headers \\ []) do
    conn =
      conn(:get, "/")
      |> put_peer_data(%{address: {10, 0, 0, 1}, port: 4000, ssl_cert: nil})
      |> Map.put(:remote_ip, {192, 0, 2, 1})

    Enum.reduce(headers, conn, fn {name, value}, conn ->
      Plug.Conn.put_req_header(conn, name, value)
    end)
  end

  describe "from_conn/1" do
    test "is the peer by default, whatever the headers or remote_ip say" do
      Application.delete_env(:ash_quick, :client_ip)

      conn = request([{"x-forwarded-for", "6.6.6.6"}, {"x-real-ip", "6.6.6.6"}])
      assert ClientIp.from_conn(conn) == "10.0.0.1"
    end

    test "reads a configured header" do
      put_client_ip({:header, "x-real-ip"})
      assert ClientIp.from_conn(request([{"x-real-ip", "203.0.113.7"}])) == "203.0.113.7"
    end

    test "falls back to the peer when the configured header is missing" do
      put_client_ip({:header, "x-real-ip"})
      assert ClientIp.from_conn(request()) == "10.0.0.1"
    end

    # What a LiveView is given, so a function written for one works for both.
    test "hands a function the peer and only the x- headers" do
      put_client_ip({IpSource, :echo, [self()]})

      request([{"x-real-ip", "203.0.113.7"}, {"user-agent", "test"}])
      |> ClientIp.from_conn()

      assert_received {:client_ip_info, info}

      assert info == %{
               peer_data: %{address: {10, 0, 0, 1}, port: 4000, ssl_cert: nil},
               x_headers: [{"x-real-ip", "203.0.113.7"}]
             }
    end

    test "agrees with what a LiveView reads off the same request" do
      put_client_ip({:header, "x-forwarded-for"})
      conn = request([{"x-forwarded-for", "6.6.6.6, 203.0.113.7"}])

      # A disconnected LiveView render reads its connect info off the conn.
      socket = %Phoenix.LiveView.Socket{private: %{connect_info: conn}}

      assert ClientIp.from_conn(conn) == "203.0.113.7"
      assert Mount.connect_ip(socket) == "203.0.113.7"
    end
  end

  describe "config_violations/1" do
    test "accepts each of the three forms" do
      assert ClientIp.config_violations(:peer) == []
      assert ClientIp.config_violations({:header, "x-real-ip"}) == []
      assert ClientIp.config_violations({:header, "X-Real-IP"}) == []
      assert ClientIp.config_violations({IpSource, :echo, [self()]}) == []
    end

    test "reads the configured value by default" do
      Application.delete_env(:ash_quick, :client_ip)
      assert ClientIp.config_violations() == []

      put_client_ip({:header, "forwarded"})
      assert [message] = ClientIp.config_violations()
      assert message =~ ~s({:header, "forwarded"})
    end

    test "refuses a header Phoenix never passes to a LiveView" do
      assert [message] = ClientIp.config_violations({:header, "forwarded"})
      assert message =~ "x-"
    end

    test "refuses a module that cannot be loaded" do
      assert [message] = ClientIp.config_violations({NoSuchModule, :ip, []})
      assert message =~ "NoSuchModule"
      assert message =~ "not a loadable module"
    end

    # The connect info goes first, so the arity is one more than the args.
    test "refuses a function not exported at the arity it is called with" do
      assert [message] = ClientIp.config_violations({IpSource, :echo, []})
      assert message =~ "IpSource.echo/1"
      assert message =~ "not exported"
    end

    test "refuses anything else, naming the three forms" do
      for bad <- [:bogus, {:header, :x_real_ip}, "x-real-ip"] do
        assert [message] = ClientIp.config_violations(bad)
        assert message =~ inspect(bad)
        assert message =~ "{module, function, args}"
      end
    end
  end
end
