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

# Presigning is offline arithmetic, but an export really uploads the file it
# generated. `Example.Test.S3Stub` is a bucket in ETS, so the bytes a reader
# would have downloaded are readable from a test.
config :ex_aws, :http_client, Example.Test.S3Stub

# `ExampleWeb.Router` serves pages over `test/support` resources only when
# this is set, the way `:dev_routes` gates the dashboard.
config :example, test_routes: true

config :ash_quick,
  check: [
    exempt: [
      # No role is granted those pages, which is what keeps them out of every
      # nav — and exactly what the check reports about a page the router serves.
      unreachable_entry: ["/test/digits_only"],
      # Tower keeps its default reporter here on purpose: it is the one that
      # holds events in memory, and `Example.ActionErrorsTest` reads what was
      # reported back from it.
      unconfigured_error_reporter: [:tower]
    ]
  ]
