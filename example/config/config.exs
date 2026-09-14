# General application configuration, loaded before any dependency.
import Config

config :ash,
  default_page_type: :keyset,
  default_string_length_count: :codepoints,
  policies: [no_filter_static_forbidden_reads?: false],
  known_types: [AshQuick.AshTypes.Attachment, AshQuick.AshTypes.Text]

# The types AshQuick ships, registered under the short names a resource spells
# in an attribute: `attribute :photo, :attachment`.
config :ash, :custom_types,
  money: AshMoney.Types.Money,
  attachment: AshQuick.AshTypes.Attachment,
  text: AshQuick.AshTypes.Text

# `:ash_quick` sorts after `:policies` and before `:pub_sub`, because the
# extension writes the `pub_sub` block itself — a section Spark does not name
# sorts last, which would put the hand-written block in the wrong place.
config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :postgres,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :ash_quick,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [section_order: [:resources, :policies, :authorization, :domain, :execution]]
  ]

config :example,
  ecto_repos: [Example.Repo],
  ash_domains: [Example.Accounts, Example.Catalog, Example.Uploads]

config :example, ExampleWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ExampleWeb.ErrorHTML, json: ExampleWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Example.PubSub,
  live_view: [signing_salt: "aQ1vT7nP"]

# Everything AshQuick needs from the application around it. `:endpoint` and
# `:actor_resource` are read with `Application.compile_env/2` — resources bake
# them in as they compile — which is why this belongs here and not in a runtime
# config file.
config :ash_quick,
  endpoint: ExampleWeb.Endpoint,
  actor_resource: Example.Accounts.User,
  audit_resource: Example.Accounts.AuditLog,
  nav: ExampleWeb.Nav,
  storage: Example.Uploads.ObjectStore,
  error_translator: {ExampleWeb.CoreComponents, :translate_error},
  timezone: "Etc/UTC"

# The two divergences this app has decided to keep. `mix ash_quick.check` reports
# everything else it finds, and `ExampleWeb.HostConformanceTest` holds it at zero.
config :ash_quick,
  check: [
    exempt: [
      # The apps grid *is* the home page, so a tile leading back to it says
      # nothing.
      tileless_route: ["/"],
      # `:reference` is taken by the upload pipeline with `authorize?: false`
      # and is forbidden to everyone else, so the button the check is warning
      # about cannot render. `/file_objects` stays read-only.
      unroutable_action: ["/file_objects/:id/reference"]
    ]
  ]

# `Example.Uploads.ObjectStore` delegates the signing to `AshQuick.Storage.S3`
# but names its own bucket, so these are only the fallback the library would use
# if the app named no store at all. Deliberately unrelated to the store's own
# bucket name, so a URL built from the wrong one is visible rather than a
# substring of the right one.
config :ash_quick,
  s3_bucket: "ash-quick-library-default",
  s3_host: "s3.invalid"

# Nothing here reaches a bucket: the presigned URL is the whole artifact, and
# ExAws refuses to sign without credentials.
config :ex_aws,
  access_key_id: "example-key",
  secret_access_key: "example-secret",
  region: "us-east-1"

# Nothing converts a currency either; the service would only reach the network.
config :ex_money, auto_start_exchange_rate_service: false

config :esbuild,
  version: "0.27.4",
  example: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.2.2",
  example: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
