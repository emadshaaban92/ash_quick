import Config

# The suite's stand-ins for the two modules a host supplies, and the bucket the
# default `AshQuick.Storage.S3` builds URLs against. `:actor_resource` and
# `:endpoint` are read with `compile_env`, so they belong here rather than in a
# test's setup — see `AshQuick.Config`.
config :ash_quick,
  actor_resource: AshQuick.Test.Actor,
  audit_resource: AshQuick.Test.AuditLog,
  s3_bucket: "ash-quick-test-bucket",
  s3_host: "s3.example.invalid"

# `AshQuick.Storage.S3` presigns through ExAws, which refuses without
# credentials. Nothing here reaches a bucket; the URLs are what is asserted.
# Nothing here converts a currency; the service would only reach the network.
config :ex_money, auto_start_exchange_rate_service: false

config :ex_aws,
  access_key_id: "ash-quick-test-key",
  secret_access_key: "ash-quick-test-secret",
  region: "us-east-1"
