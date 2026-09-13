import Config

# Required by Ash; the setting is about how `min_length`/`max_length` count, and
# `:codepoints` is what a SQL data layer does. A host makes this choice for
# itself — it is here so this project's own resources compile.
config :ash, default_string_length_count: :codepoints

# The types this library ships, registered under the short names a host would
# spell in an attribute: `attribute :photo, :attachment`.
config :ash, :custom_types,
  attachment: AshQuick.AshTypes.Attachment,
  text: AshQuick.AshTypes.Text

config :ash, known_types: [AshQuick.AshTypes.Attachment, AshQuick.AshTypes.Text]

import_config "#{config_env()}.exs"
