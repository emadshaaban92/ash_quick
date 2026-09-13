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
  """
  use ExUnit.Case, async: true

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
