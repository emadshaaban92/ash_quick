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

# Only the cases that swap `:storage` to `AshQuick.Storage.Local` write here;
# the router forwards `/test/files` to its plug.
config :ash_quick, AshQuick.Storage.Local,
  root: Path.join(System.tmp_dir!(), "ash_quick_example_local_storage"),
  endpoint: ExampleWeb.Endpoint,
  at: "/test/files"

# Only the cases that swap `:storage` to `AshQuick.Storage.S3.Proxy` read and
# write this bucket, through `Example.Test.S3Stub`; the router forwards
# `/test/proxied_files` to its plug.
config :ash_quick, AshQuick.Storage.S3.Proxy,
  bucket: "ash-quick-example-proxied",
  endpoint: ExampleWeb.Endpoint,
  at: "/test/proxied_files"

# `ExampleWeb.Router` serves pages over `test/support` resources only when
# this is set, the way `:dev_routes` gates the dashboard.
config :example, test_routes: true

config :ash_quick,
  check: [
    exempt: [
      # No role is granted those pages, which is what keeps them out of every
      # nav — and exactly what the check reports about a page the router serves.
      unreachable_entry: [
        "/test/atomic_brands",
        "/test/brand_filter",
        "/test/bulk_guarded",
        "/test/bulk_named",
        "/test/dated_entries",
        "/test/default_pages",
        "/test/digits_only",
        "/test/downloadable",
        "/test/enum_picks",
        "/test/field_rows",
        "/test/filter_fields",
        "/test/filter_fields_drawn_named",
        "/test/filter_fields_drawn_none",
        "/test/filter_fields_named",
        "/test/filter_fields_none",
        "/test/filter_fields_salary",
        "/test/form_stages",
        "/test/hidden_address",
        "/test/hidden_fields",
        "/test/labelled_loans",
        "/test/last_writes",
        "/test/long_forms",
        "/test/lookup_items",
        "/test/nested_items",
        "/test/offset_pages",
        "/test/picked_labels",
        "/test/picked_rows",
        "/test/printable",
        "/test/private_create",
        "/test/related_filter",
        "/test/related_filter_default",
        "/test/required_attachments",
        "/test/required_entries",
        "/test/required_picks",
        "/test/second_lists",
        "/test/secrets",
        "/test/shelved_crates",
        "/test/small_pages",
        "/test/sorted_rows",
        "/test/sorted_rows_named",
        "/test/uncounted_pages",
        "/test/vault_filter",
        "/test/wide_offset_pages",
        "/test/worded_policy",
        "/test/writers_only"
      ],
      # Tower keeps its default reporter here on purpose: it is the one that
      # holds events in memory, and `Example.ActionErrorsTest` reads what was
      # reported back from it.
      unconfigured_error_reporter: [:tower]
    ]
  ]

# Prints come back as the template's HTML behind a PDF header, read off the
# pushed event, rather than through a Chrome. Only the test build prints
# (`Example.Test.Printable`), so only it names a renderer: elsewhere
# `AshQuick.Print.Verifier` would refuse a print as its resource compiles.
config :ash_quick, pdf_renderer: Example.Test.PdfRendererDouble
