defmodule ExampleWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :example

  @session_options [
    store: :cookie,
    key: "_example_key",
    signing_salt: "n2Kd8Lq1",
    same_site: "Lax"
  ]

  # `:peer_data` and `:x_headers` are what `AshQuick.LiveView.Mount.ip/1` reads
  # the request address from; without them every audited write records no
  # address and nothing says so. `AshQuick.LiveView.Mount.connect_info_violations/1`
  # is the assertion — see `test/example_web/host_conformance_test.exs`.
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, :x_headers, session: @session_options]],
    longpoll: [connect_info: [:peer_data, :x_headers, session: @session_options]]

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
