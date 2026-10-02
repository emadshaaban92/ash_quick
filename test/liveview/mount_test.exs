defmodule AshQuick.LiveView.MountTest do
  @moduledoc """
  The one thing about a mount that no page can show.

  Everything this stage establishes is observable somewhere a test can drive:
  the impersonated actor through the banner and the live sessions page, and the
  address through the audit rows a write leaves.

  A misconfigured endpoint is the exception. It does not fail — it reports no
  address, and a blank IP column is indistinguishable from a request that
  genuinely had none. The assertion has to be made against the endpoint's
  declaration, which is what `connect_info_violations/1` is for.

  Where the address comes from is the other: `connect_ip/1` reads global
  config, so this module runs alone.
  """
  use ExUnit.Case, async: false

  alias AshQuick.LiveView.Mount

  defmodule ProperEndpoint do
    @moduledoc false
    def __sockets__ do
      [
        {"/live", Phoenix.LiveView.Socket,
         [websocket: [connect_info: [:peer_data, :x_headers, session: []]]]}
      ]
    end
  end

  defmodule PartialEndpoint do
    @moduledoc false
    def __sockets__ do
      [{"/live", Phoenix.LiveView.Socket, [websocket: [connect_info: [:peer_data]]]}]
    end
  end

  defmodule DefaultTransportEndpoint do
    @moduledoc false
    def __sockets__, do: [{"/live", Phoenix.LiveView.Socket, [websocket: true]}]
  end

  defmodule LongpollEndpoint do
    @moduledoc false
    def __sockets__ do
      [
        {"/live", Phoenix.LiveView.Socket,
         [
           websocket: [connect_info: [:peer_data, :x_headers]],
           longpoll: [connect_info: [:peer_data]]
         ]}
      ]
    end
  end

  defmodule NoLiveSocketEndpoint do
    @moduledoc false
    def __sockets__, do: [{"/socket", SomeOtherSocket, [websocket: [connect_info: []]]}]
  end

  defmodule NotAnEndpoint do
    @moduledoc false
  end

  defmodule ClientIp do
    @moduledoc false
    def echo(info, test_pid, answer) do
      send(test_pid, {:client_ip_info, info})
      answer
    end
  end

  # Shaped the way `Phoenix.LiveView.get_connect_info/2` reads a connected
  # socket: a map under `private.connect_info`, missing keys reading as `nil`.
  defp socket(connect_info) do
    %Phoenix.LiveView.Socket{private: %{connect_info: connect_info}}
  end

  defp connected(x_headers, peer \\ {10, 0, 0, 1}) do
    socket(%{peer_data: %{address: peer, port: 4000, ssl_cert: nil}, x_headers: x_headers})
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

  @spoofing [{"x-forwarded-for", "6.6.6.6"}, {"x-real-ip", "6.6.6.6"}]

  describe "connect_ip/1 with :peer" do
    # The client wrote both headers, so neither may decide its address.
    test "is the default, and ignores forwarded headers" do
      Application.delete_env(:ash_quick, :client_ip)

      assert Mount.connect_ip(connected(@spoofing)) == "10.0.0.1"
    end

    test "configured, ignores forwarded headers" do
      put_client_ip(:peer)
      assert Mount.connect_ip(connected(@spoofing)) == "10.0.0.1"
    end

    test "is nil with no peer data" do
      put_client_ip(:peer)
      assert Mount.connect_ip(socket(%{x_headers: @spoofing})) == nil
    end
  end

  describe "connect_ip/1 with {:header, name}" do
    test "reads a single value" do
      put_client_ip({:header, "x-real-ip"})
      assert Mount.connect_ip(connected([{"x-real-ip", "203.0.113.7"}])) == "203.0.113.7"
    end

    test "matches a configured name in any case" do
      put_client_ip({:header, "X-Real-IP"})
      assert Mount.connect_ip(connected([{"x-real-ip", "203.0.113.7"}])) == "203.0.113.7"
    end

    # The proxy appends; whatever comes before its entry is the client's to write.
    test "takes the last entry of a list" do
      put_client_ip({:header, "x-forwarded-for"})

      assert Mount.connect_ip(connected([{"x-forwarded-for", "6.6.6.6, 203.0.113.7"}])) ==
               "203.0.113.7"
    end

    test "takes the last occurrence of a repeated header" do
      put_client_ip({:header, "x-real-ip"})

      headers = [{"x-real-ip", "6.6.6.6"}, {"x-real-ip", "203.0.113.7"}]
      assert Mount.connect_ip(connected(headers)) == "203.0.113.7"
    end

    test "falls back to the peer when the header is missing" do
      put_client_ip({:header, "x-real-ip"})
      assert Mount.connect_ip(connected([{"x-forwarded-for", "203.0.113.7"}])) == "10.0.0.1"
    end

    test "falls back to the peer when the value is not an IP" do
      put_client_ip({:header, "x-real-ip"})
      assert Mount.connect_ip(connected([{"x-real-ip", "unknown"}])) == "10.0.0.1"
      assert Mount.connect_ip(connected([{"x-real-ip", ""}])) == "10.0.0.1"
      assert Mount.connect_ip(connected([{"x-real-ip", <<0xFF>>}])) == "10.0.0.1"
    end

    test "formats an IPv6 value as it formats an IPv6 peer" do
      put_client_ip({:header, "x-real-ip"})
      peer = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}

      assert Mount.connect_ip(connected([{"x-real-ip", "2001:DB8:0:0::1"}])) ==
               Mount.connect_ip(connected([], peer))

      assert Mount.connect_ip(connected([], peer)) == "2001:db8::1"
    end

    test "refuses a header Phoenix never passes to a LiveView" do
      put_client_ip({:header, "forwarded"})

      error = assert_raise ArgumentError, fn -> Mount.connect_ip(connected([])) end
      assert error.message =~ ~s({:header, "forwarded"})
      assert error.message =~ "x-"
      assert error.message =~ "{module, function, args}"
    end
  end

  describe "connect_ip/1 with {module, function, args}" do
    test "passes the connect info and the extra args through" do
      put_client_ip({ClientIp, :echo, [self(), nil]})
      Mount.connect_ip(connected([{"x-real-ip", "203.0.113.7"}]))

      assert_received {:client_ip_info, info}

      assert info == %{
               peer_data: %{address: {10, 0, 0, 1}, port: 4000, ssl_cert: nil},
               x_headers: [{"x-real-ip", "203.0.113.7"}]
             }
    end

    test "formats the address it returns" do
      put_client_ip({ClientIp, :echo, [self(), "2001:DB8:0:0::1"]})
      assert Mount.connect_ip(connected([])) == "2001:db8::1"
    end

    # The function decided there is no address; the peer does not overrule it.
    test "keeps nil as nil, peer data or not" do
      put_client_ip({ClientIp, :echo, [self(), nil]})
      assert Mount.connect_ip(connected([])) == nil
    end

    test "refuses a return that is not an IP" do
      put_client_ip({ClientIp, :echo, [self(), "unknown"]})

      error = assert_raise ArgumentError, fn -> Mount.connect_ip(connected([])) end
      assert error.message =~ "ClientIp.echo/3"
      assert error.message =~ ~s("unknown")
    end
  end

  test "connect_ip/1 refuses any other :client_ip, naming the three forms" do
    put_client_ip(:bogus)

    error = assert_raise ArgumentError, fn -> Mount.connect_ip(connected([])) end
    assert error.message =~ ":bogus"
    assert error.message =~ ":peer"
    assert error.message =~ "{:header, name}"
    assert error.message =~ "{module, function, args}"
  end

  describe "connect_info_violations/1" do
    test "a declaration naming both keys satisfies it" do
      assert Mount.connect_info_violations(ProperEndpoint) == []
    end

    test "a missing key names itself, so the fix is the sentence" do
      assert [violation] = Mount.connect_info_violations(PartialEndpoint)
      assert violation =~ ":x_headers"
      assert violation =~ "/live"
      assert violation =~ "records no IP"
      refute violation =~ ":peer_data"
    end

    test "a transport left at its defaults offers no connect info at all" do
      assert [violation] = Mount.connect_info_violations(DefaultTransportEndpoint)
      assert violation =~ ":peer_data"
      assert violation =~ ":x_headers"
    end

    # A host serving both transports has two ways in, and a browser that falls
    # back to longpoll is exactly the one behind the proxy worth naming.
    test "every transport is checked, not just the first" do
      assert [violation] = Mount.connect_info_violations(LongpollEndpoint)
      assert violation =~ "longpoll"
      assert violation =~ ":x_headers"
    end

    test "an endpoint nothing mounts through is reported rather than passing" do
      assert [violation] = Mount.connect_info_violations(NoLiveSocketEndpoint)
      assert violation =~ "declares no Phoenix.LiveView.Socket"
    end

    test "a module that is not an endpoint is reported rather than crashing" do
      assert [violation] = Mount.connect_info_violations(NotAnEndpoint)
      assert violation =~ "is not a Phoenix endpoint"

      assert [violation] = Mount.connect_info_violations(NoSuchModuleAnywhere)
      assert violation =~ "not a loadable module"
    end
  end
end
