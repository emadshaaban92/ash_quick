import Config

# This app is a test host and a local demo; it is never deployed. The file
# exists so `MIX_ENV=prod mix compile` still resolves a config.
config :example, ExampleWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

config :logger, level: :info
