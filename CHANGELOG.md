# Changelog

## Unreleased

### Breaking changes

- **The `:active` attribute activation adds is now NOT NULL** (`allow_nil?:
  false`, still `default: true`). A `nil` `active` was a third state nothing in
  AshQuick meant: the BelongsTo/HasMany dropdowns hid the record as if it were
  inactive, while the row actions offered it both `:activate` and
  `:deactivate`. Creates and updates now refuse `active: nil`.

  **Migrating:** a host with an existing nullable `active` column gets a
  migration from `mix ash.codegen` that sets it NOT NULL, and that migration
  fails while any row holds `NULL`. Backfill first, for example
  `UPDATE <table> SET active = true WHERE active IS NULL`, or decide per row
  which of the two states it is in.

  A resource that defines its own `:active` attribute is unaffected: the
  extension still adds the attribute only when it is absent, so that
  resource's own `allow_nil?` stands.
