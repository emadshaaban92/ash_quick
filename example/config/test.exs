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
  # Only a run that includes the browser tests serves it, which
  # `test/test_helper.exs` turns on.
  server: false

# A browser test's requests and LiveViews join its database transaction. See
# `ExampleWeb.SqlSandbox`.
config :example, sql_sandbox: true

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime
config :phoenix, :sort_verified_routes_query_params, true

config :phoenix_live_view, enable_expensive_runtime_checks: true

config :phoenix_test, :endpoint, ExampleWeb.Endpoint

# The browser tests (`test/browser`, tagged `:playwright`): Chromium, driven
# through the Playwright `assets/package.json` installs. One browser at a time,
# since the pages they drive share ETS tables. Each assertion waits up to 5s
# for the page. `PW_SCREENSHOT=true` keeps a screenshot of each test's last
# page under `screenshots/`, and `PW_TRACE=true` a Playwright trace under
# `traces/`. `PW_CHROMIUM` names a Chromium to run instead of the one
# Playwright installs, for a machine that cannot download it.
config :phoenix_test,
  otp_app: :example,
  playwright:
    [
      browser_pools: [[id: :chromium, browser: :chromium, size: 1]],
      browser_pool: :chromium,
      timeout: to_timeout(second: 5),
      trace: System.get_env("PW_TRACE", "false") in ~w(t true),
      screenshot: System.get_env("PW_SCREENSHOT", "false") in ~w(t true)
    ] ++ if(path = System.get_env("PW_CHROMIUM"), do: [executable_path: path], else: [])

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

# The pages `ExampleWeb.Router` serves over `test/support` resources. No role is
# granted them, which keeps them out of every nav, and their live session runs no
# `AshQuick.LiveView.RouteGate`, since a test drives each one as whatever actor
# it needs. Both are what the check reports about a page the router serves.
test_pages = [
  "/test/actor_rows",
  "/test/atomic_brands",
  "/test/brand_filter",
  "/test/brand_record_filter",
  "/test/bulk_guarded",
  "/test/bulk_named",
  "/test/checkbox_widths",
  "/test/counted_bins",
  "/test/counted_box_codes",
  "/test/counted_boxes",
  "/test/created_picks",
  "/test/dated_entries",
  "/test/default_pages",
  "/test/digits_only",
  "/test/downloadable",
  "/test/enum_picks",
  "/test/field_rows",
  "/test/filter_fields",
  "/test/filter_fields_cells",
  "/test/filter_fields_drawn_named",
  "/test/filter_fields_drawn_none",
  "/test/filter_fields_named",
  "/test/filter_fields_none",
  "/test/filter_fields_salary",
  "/test/form_inputs",
  "/test/form_stages",
  "/test/hidden_address",
  "/test/hidden_fields",
  "/test/labelled_loans",
  "/test/last_writes",
  "/test/live_rows",
  "/test/long_forms",
  "/test/managed_nest",
  "/test/keyed_rows",
  "/test/keyed_items",
  "/test/seat_rows",
  "/test/managed_rows",
  "/test/managed_rows_held",
  "/test/managed_rows_narrow",
  "/test/managed_rows_locked",
  "/test/managed_rows_hidden",
  "/test/lookup_items",
  "/test/named_rows",
  "/test/named_rows_counted",
  "/test/nested_items",
  "/test/offset_pages",
  "/test/picked_labels",
  "/test/picked_rows",
  "/test/printable",
  "/test/record_filter",
  "/test/picked_places",
  "/test/private_create",
  "/test/quiet_writes",
  "/test/related_filter",
  "/test/related_filter_default",
  "/test/related_filter_defaults",
  "/test/required_attachments",
  "/test/required_entries",
  "/test/required_picks",
  "/test/second_lists",
  "/test/secrets",
  "/test/shadowed_arguments",
  "/test/shaped_bundles",
  "/test/shaped_orders",
  "/test/shelved_crates",
  "/test/small_pages",
  "/test/sorted_rows",
  "/test/sorted_rows_named",
  "/test/sourced_labels",
  "/test/stored_map_lists",
  "/test/two_file_rows",
  "/test/typed_inputs",
  "/test/uncounted_pages",
  "/test/unseen_keepers",
  "/test/value_lists",
  "/test/vault_filter",
  "/test/wide_offset_pages",
  "/test/worded_policy",
  "/test/writers_only"
]

config :ash_quick,
  check: [
    exempt: [
      unreachable_entry: test_pages,
      ungated_quick_view: test_pages,
      # Tower keeps its default reporter here on purpose: it is the one that
      # holds events in memory, and `Example.ActionErrorsTest` reads what was
      # reported back from it.
      unconfigured_error_reporter: [:tower],
      # A join no page renders, keyed by its pair of ids.
      missing_extension: [Example.Catalog.ProductLabel]
    ]
  ]

# Prints come back as the template's HTML behind a PDF header, read off the
# pushed event, rather than through a Chrome. Only the test build prints
# (`Example.Test.Printable`), so only it names a renderer: elsewhere
# `AshQuick.Print.Verifier` would refuse a print as its resource compiles.
config :ash_quick, pdf_renderer: Example.Test.PdfRendererDouble

# A type of the host's drawn by an input of its own, as a scalar and as a
# list, and a `Money` NewType given the plain text input rather than
# AshQuick's own. See `Example.Test.FormInputs`.
config :ash_quick,
  form_inputs: %{
    Example.Test.FormInputs.Phone => Example.Test.FormInputs.PhoneInput,
    {:array, Example.Test.FormInputs.Phone} => Example.Test.FormInputs.PhonesInput,
    Example.Test.FormInputs.PlainPrice => false
  }
