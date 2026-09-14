import Config

config :ash, policies: [show_policy_breakdowns?: true]

config :example, Example.Repo,
  username: "admin",
  password: "admin",
  hostname: "db",
  database: "example_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :example, ExampleWeb.Endpoint,
  # Bound to every interface so the demo is reachable from the docker host.
  # `PORT` is read here because dev is the only environment this app runs a
  # server in — there is no runtime.exs, as it is never released.
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
  check_origin: false,
  code_reloader: true,
  # The library recompiles with the app, so editing it reloads the browser.
  reloadable_apps: [:example, :ash_quick],
  debug_errors: true,
  secret_key_base: "PJ0Wq8lYVv1m8j5Q2rXcT6nH4bG9sKdA3fUeR7yZpLmNwXvC1kBtQi5oJhSgErDu",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:example, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:example, ~w(--watch)]}
  ],
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/.*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
      ~r"priv/gettext/.*\.po$"E,
      ~r"lib/example_web/router\.ex$"E,
      ~r"lib/example_web/(controllers|live|components)/.*\.(ex|heex)$"E,
      ~r"lib/example/.*\.(ex|heex)$"E,
      ~r"lib/ash_quick/.*\.(ex|heex)$"E
    ]
  ]

# Watch the library checkout as well as this app, so a change to a QuickView
# component reloads the page that renders it.
config :phoenix_live_reload, :dirs, [Path.expand(".."), Path.expand(".")]

config :example, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true
