defmodule AshQuick.ClientIp do
  @moduledoc """
  The client's address, read from wherever `config :ash_quick, client_ip: ...`
  says. See `AshQuick.Config.client_ip/0` for the three forms it takes.

  There are two ways in, and they give the same answer for the same request:

    * `AshQuick.LiveView.Mount.connect_ip/1`, for a LiveView. The mount assigns
      it, and `AshQuick.LiveView.Mount.ip/1` reads it back.
    * `from_conn/1`, for a controller or a plug: whatever builds a scope from a
      `Plug.Conn` rather than a socket.

  A host that builds its controller scope from `conn.remote_ip` records a
  different address from its LiveViews as soon as `:client_ip` names a header:
  the proxy's on one, the client's on the other. `from_conn/1` exists so the
  two agree.

  `config_violations/1` is the check a host's test suite runs, because a
  `:client_ip` that is wrong only raises once something connects.
  """

  alias AshQuick.Config

  @typedoc """
  What an address is read from: the two `:connect_info` keys
  `AshQuick.LiveView.Mount` needs, shaped as `Phoenix.LiveView.get_connect_info/2`
  returns them. Either is `nil` when the endpoint does not offer it.
  """
  @type info :: %{peer_data: map() | nil, x_headers: [{String.t(), String.t()}] | nil}

  @doc """
  The address `conn` came from, read the way a LiveView's connection is.

  The peer is `Plug.Conn.get_peer_data/1`, not `conn.remote_ip`, and the headers
  are the ones starting with `x-`, which are all a LiveView is given. A plug that
  rewrites `conn.remote_ip` therefore does not change the answer: name the same
  source in `:client_ip` instead, so the controllers and the LiveViews agree.

  Raises as `resolve/1` does.
  """
  @spec from_conn(Plug.Conn.t()) :: String.t() | nil
  def from_conn(%Plug.Conn{} = conn) do
    resolve(%{peer_data: Plug.Conn.get_peer_data(conn), x_headers: x_headers(conn)})
  end

  @doc """
  The address `info` gives, according to the configured `:client_ip`.

  `nil` when the source it names has no address to give.

  Raises `ArgumentError` when `:client_ip` is not one of the forms it accepts,
  or when a `{module, function, args}` returns something other than `nil` or an
  IP address string.
  """
  @spec resolve(info()) :: String.t() | nil
  def resolve(info), do: resolve(Config.client_ip(), info)

  @doc """
  The ways `source` falls short of a `:client_ip` that can be read, as a list of
  sentences. Empty when there are none. Defaults to the configured one.

  Nothing calls this on a host's behalf, and AshQuick has no application of its
  own to call it at boot. A bad value only raises when something connects, so a
  host catches it before a deploy by asserting this is empty in a test:

      test "the client IP source can be read" do
        assert AshQuick.ClientIp.config_violations() == []
      end

  Run that test with the configuration production uses. A value set in
  `runtime.exs` for production only is not the one the test environment sees.
  """
  @spec config_violations(term()) :: [String.t()]
  def config_violations(source \\ Config.client_ip())

  def config_violations(:peer), do: []

  def config_violations({:header, name}) when is_binary(name) do
    if x_header?(name), do: [], else: [unreadable_header(name)]
  end

  def config_violations({module, function, args})
      when is_atom(module) and is_atom(function) and is_list(args) do
    arity = length(args) + 1

    cond do
      not Code.ensure_loaded?(module) ->
        [
          "config :ash_quick, client_ip: names #{inspect(module)}, which is not a " <>
            "loadable module."
        ]

      not function_exported?(module, function, arity) ->
        [
          "config :ash_quick, client_ip: names #{inspect(module)}.#{function}/#{arity}, " <>
            "which is not exported. It is called with the connect info ahead of the " <>
            "#{length(args)} configured argument(s)."
        ]

      true ->
        []
    end
  end

  def config_violations(other), do: [unknown_form(other)]

  defp resolve(:peer, info), do: peer_ip(info)

  defp resolve({:header, configured}, info) when is_binary(configured) do
    if not x_header?(configured), do: raise(ArgumentError, unreadable_header(configured))

    header_ip(info, String.downcase(configured)) || peer_ip(info)
  end

  # The function has already decided, so its `nil` is not second-guessed with
  # the peer address.
  defp resolve({module, function, args} = mfa, info)
       when is_atom(module) and is_atom(function) and is_list(args) do
    case apply(module, function, [info | args]) do
      nil -> nil
      address when is_binary(address) -> parse(address) || raise_bad_return(mfa, address)
      other -> raise_bad_return(mfa, other)
    end
  end

  defp resolve(other, _info), do: raise(ArgumentError, unknown_form(other))

  defp x_header?(name), do: name |> String.downcase() |> String.starts_with?("x-")

  defp unreadable_header(name) do
    "config :ash_quick, client_ip: {:header, #{inspect(name)}} names a header " <>
      "AshQuick can never read: Phoenix's :x_headers connect info holds only " <>
      "headers starting with \"x-\", so every connection would fall back to " <>
      "the peer address. Have the proxy set an x- header instead, or read the " <>
      "address yourself with a {module, function, args}."
  end

  defp unknown_form(other) do
    "config :ash_quick, client_ip: must be :peer, {:header, name} with name a " <>
      "string, or {module, function, args}; got: #{inspect(other)}"
  end

  defp raise_bad_return({module, function, args}, returned) do
    raise ArgumentError,
          "#{inspect(module)}.#{function}/#{length(args) + 1}, configured as " <>
            ":client_ip, must return nil or an IP address string; it returned: " <>
            inspect(returned)
  end

  # What `Phoenix.LiveView.get_connect_info/2` gives a LiveView for `:x_headers`.
  defp x_headers(conn) do
    for {name, _value} = header <- conn.req_headers, String.starts_with?(name, "x-"), do: header
  end

  # The last occurrence and its last entry are the ones the nearest proxy wrote;
  # anything before them came from further away, the client included.
  defp header_ip(%{x_headers: headers}, name) when is_list(headers) do
    case headers |> Enum.reverse() |> List.keyfind(name, 0) do
      {_name, value} -> value |> String.split(",") |> List.last() |> String.trim() |> parse()
      nil -> nil
    end
  end

  defp header_ip(_info, _name), do: nil

  # Bytewise, so a value that is not UTF-8 is refused by the parser rather than
  # crashing the mount.
  defp parse(address) do
    case address |> :erlang.binary_to_list() |> :inet.parse_address() do
      {:ok, ip} -> format(ip)
      {:error, _reason} -> nil
    end
  end

  defp peer_ip(%{peer_data: %{address: address}}), do: format(address)
  defp peer_ip(_info), do: nil

  defp format(address), do: address |> :inet.ntoa() |> to_string()
end
