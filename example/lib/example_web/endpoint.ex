defmodule ExampleWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :example

  @session_options [
    store: :cookie,
    key: "_example_key",
    signing_salt: "n2Kd8Lq1",
    same_site: "Lax"
  ]

  @doc "The options the session cookie is written with."
  def session_options, do: @session_options

  # `:peer_data` is what `AshQuick.LiveView.Mount.ip/1` reads the request
  # address from, and `:x_headers` is where a header named in
  # `config :ash_quick, client_ip: ...` would be read from. Without them every
  # audited write records no address and nothing says so.
  # `AshQuick.LiveView.Mount.connect_info_violations/1` is the assertion; see
  # `test/example_web/host_conformance_test.exs`.
  #
  # The test build adds `:user_agent`, which carries a browser test's sandbox
  # metadata; see `ExampleWeb.SqlSandbox`.
  @connect_info [:peer_data, :x_headers] ++
                  if(Application.compile_env(:example, :sql_sandbox), do: [:user_agent], else: [])

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: @connect_info ++ [session: @session_options]],
    longpoll: [connect_info: @connect_info ++ [session: @session_options]]

  # Only the test build: a browser test's requests join its database
  # transaction. See `ExampleWeb.SqlSandbox`.
  if Application.compile_env(:example, :sql_sandbox) do
    plug Phoenix.Ecto.SQL.Sandbox
  end

  plug Plug.Static,
    at: "/",
    from: :example,
    gzip: not code_reloading?,
    only: ExampleWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if Code.ensure_loaded?(Tidewave) do
    plug Tidewave
  end

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug AshPhoenix.Plug.CheckCodegenStatus
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :example
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug ExampleWeb.Router
end
