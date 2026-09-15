import Config

config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

config :example, Example.Repo,
  username: "admin",
  password: "admin",
  hostname: "db",
  database: "example_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :example, ExampleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Yb3sXqNvE8mR1tKzP5gWjA7cHdLuF2oZi6QeTyVnMxBrJ4kSaC0pDlUhGwIfOt9K",
  server: false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime
config :phoenix, :sort_verified_routes_query_params, true

config :phoenix_live_view, enable_expensive_runtime_checks: true

config :phoenix_test, :endpoint, ExampleWeb.Endpoint
