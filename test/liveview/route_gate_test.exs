defmodule AshQuick.LiveView.RouteGateTest do
  @moduledoc """
  What the route gate answers for a scope and a path, driven through the hook
  it attaches.

  The pages a host serves through it are driven in the example app, which runs
  it in its authenticated live session. What is here is the answer on its own:
  which paths a scope is let through to, what a refusal is, and the
  misconfiguration it will not mount over.
  """
  use ExUnit.Case, async: true

  alias AshQuick.BrowserSession
  alias AshQuick.LiveView.RouteGate
  alias AshQuick.LiveView.RouteGate.NotAllowedError
  alias AshQuick.Test.Nav.AccessControl
  alias AshQuick.Test.Nav.Router
  alias AshQuick.Test.Nav.Scope
  alias Phoenix.LiveView.Socket

  defp socket(assigns \\ %{}, router \\ Router) do
    %Socket{
      router: router,
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns),
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }
  end

  defp scope(roles), do: %Scope{roles: roles}

  defp mount(socket, opts \\ [access_control: AccessControl]) do
    {:cont, socket} = RouteGate.on_mount(opts, %{}, %{}, socket)
    socket
  end

  # The hook the gate attached, run as LiveView runs it on a navigation.
  defp navigate(socket, uri) do
    [%{id: :ash_quick_route_gate, function: hook}] = socket.private.lifecycle.handle_params
    hook.(%{}, uri, socket)
  end

  defmodule Anonymous do
    @moduledoc false
    @behaviour AshQuick.AccessControl

    @impl true
    def routes_for(nil), do: []
    def routes_for(_scope), do: ["/products"]
  end

  defmodule HomeOnly do
    @moduledoc false
    @behaviour AshQuick.AccessControl

    @impl true
    def routes_for(_scope), do: ["/"]
  end

  defmodule TrailingSlash do
    @moduledoc false
    @behaviour AshQuick.AccessControl

    @impl true
    def routes_for(_scope), do: ["/products/"]
  end

  describe "allowed?/3" do
    test "a route covers itself and every path under it, and nothing else" do
      admin = scope([:admin])

      assert RouteGate.allowed?(AccessControl, admin, "/products")
      assert RouteGate.allowed?(AccessControl, admin, "/products/123")
      assert RouteGate.allowed?(AccessControl, admin, "/scan/history")
      refute RouteGate.allowed?(AccessControl, admin, "/products_archive")
      refute RouteGate.allowed?(AccessControl, admin, "/users")
    end

    # Phoenix drops empty segments, so `//users` is served as `/users`. Matched
    # as written, a `/` grant would cover it.
    test "a path is matched with its empty segments dropped" do
      for path <- ["//users", "///users", "//users/1", "/users/"] do
        refute RouteGate.allowed?(HomeOnly, %{}, path), path
      end

      assert RouteGate.allowed?(HomeOnly, %{}, "/")
      assert RouteGate.allowed?(HomeOnly, %{}, "//")
      assert RouteGate.allowed?(AccessControl, scope([:catalog]), "//products//1")
      refute RouteGate.allowed?(AccessControl, scope([:catalog]), "//scan")
    end

    # Both sides are read the same way, so a grant written with a trailing
    # slash still covers the page it names.
    test "a route is matched with its empty segments dropped too" do
      assert RouteGate.allowed?(TrailingSlash, %{}, "/products")
      assert RouteGate.allowed?(TrailingSlash, %{}, "/products/")
      assert RouteGate.allowed?(TrailingSlash, %{}, "/products/1")
      refute RouteGate.allowed?(TrailingSlash, %{}, "/products_archive")
      refute RouteGate.allowed?(HomeOnly, %{}, "/products")
    end

    test "a missing path is the root" do
      assert RouteGate.allowed?(HomeOnly, %{}, nil)
      refute RouteGate.allowed?(AccessControl, scope([:catalog]), nil)
    end

    test "a scope holding no role, or no scope at all, holds no route" do
      refute RouteGate.allowed?(AccessControl, scope([]), "/products")
      refute RouteGate.allowed?(AccessControl, scope([:unknown]), "/products")
    end
  end

  describe "a navigation" do
    test "to a granted route goes ahead" do
      socket = %{scope: scope([:catalog])} |> socket() |> mount()

      assert {:cont, %Socket{}} = navigate(socket, "http://localhost/products/1?action=update")
    end

    test "to a route the scope was not granted raises a 403" do
      socket = %{scope: scope([:catalog])} |> socket() |> mount()

      error = assert_raise NotAllowedError, fn -> navigate(socket, "http://localhost/scan") end

      assert error.path == "/scan"
      assert Plug.Exception.status(error) == 403
    end

    test "to a doubled slash is refused as the path the router serves" do
      socket = %{scope: %{}} |> socket() |> mount(access_control: HomeOnly)

      assert_raise NotAllowedError, fn -> navigate(socket, "http://localhost//users") end
      assert {:cont, %Socket{}} = navigate(socket, "http://localhost/")
    end

    # The query is where a QuickView keeps its filters and its open action,
    # and none of it is a route.
    test "is matched on its path, not its query" do
      socket = %{scope: scope([:catalog])} |> socket() |> mount()

      assert_raise NotAllowedError, fn ->
        navigate(socket, "http://localhost/scan?return=/products")
      end
    end

    # Asked with `nil`, which an access control answers with no route.
    test "with no scope assigned is refused" do
      socket = socket() |> mount(access_control: __MODULE__.Anonymous)

      assert_raise NotAllowedError, fn -> navigate(socket, "http://localhost/products") end
    end
  end

  describe "a tab standing in for somebody" do
    defp impersonating(roles) do
      socket(%{
        scope: scope(roles),
        ash_quick_browser_session: %BrowserSession{id: "tab", actor: %{id: "someone"}}
      })
    end

    test "is sent to the fallback with a flash rather than raised at" do
      socket = [:catalog] |> impersonating() |> mount()

      assert {:halt, socket} = navigate(socket, "http://localhost/scan")
      assert socket.redirected == {:live, :redirect, %{kind: :push, to: "/"}}
      assert socket.assigns.flash["error"] =~ "/scan"
    end

    test "is sent where `fallback:` says" do
      socket =
        [:catalog]
        |> impersonating()
        |> mount(access_control: AccessControl, fallback: "/products")

      assert {:halt, socket} = navigate(socket, "http://localhost/scan")
      assert socket.redirected == {:live, :redirect, %{kind: :push, to: "/products"}}
    end

    # Compared as the router reads it, a fallback with a query or a trailing
    # slash is still the page it names, and is not navigated to again.
    test "refused a fallback written with a query or a trailing slash is raised at" do
      for fallback <- ["/products?tab=1", "/products/"] do
        socket =
          []
          |> impersonating()
          |> mount(access_control: AccessControl, fallback: fallback)

        assert_raise NotAllowedError, fn -> navigate(socket, "http://localhost/products") end
      end
    end

    # Sending it on to the page it was refused would only refuse it again.
    test "refused the fallback itself is raised at" do
      socket = [] |> impersonating() |> mount()

      assert_raise NotAllowedError, fn -> navigate(socket, "http://localhost/") end
    end
  end

  describe "mounting" do
    test "without an access control to ask raises" do
      assert_raise ArgumentError, ~r/no access control to ask/, fn ->
        RouteGate.on_mount([access_control: nil], %{}, %{}, socket())
      end
    end

    # The suite configures no nav, so there is nothing to read one off.
    test "with no nav configured and none given raises" do
      assert_raise ArgumentError, ~r/no access control to ask/, fn ->
        RouteGate.on_mount(:default, %{}, %{}, socket())
      end
    end

    test "a LiveView not mounted at the router is let through with no hook" do
      socket = %{} |> socket(nil) |> mount()

      assert socket.private.lifecycle.handle_params == []
    end

    # A `live_render` child inherits its parent's router, and LiveView refuses
    # it a `handle_params` hook. The example app drives a real one.
    test "a nested or sticky LiveView is let through with no hook" do
      for child <- [%{socket() | parent_pid: self()}, %{socket() | sticky?: true}] do
        socket = mount(child)

        assert socket.private.lifecycle.handle_params == []
      end
    end
  end
end
