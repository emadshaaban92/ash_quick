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

- **The creation timestamp follows Ash's name: `inserted_at`, not
  `created_at`.** Both the bookkeeping DSL option and the default attribute
  are renamed, so the declaration reads `inserted_at :inserted_at` /
  `updated_at :updated_at`, matching what Ash's `timestamps()` defines.
  `AshQuick.Info.inserted_at_field/1` replaces `created_at_field/1`, and the
  key in `AshQuick.Info.bookkeeping/1` is `:inserted_at`. A resource already
  calling `timestamps(always_select?: true)` now satisfies the defaults; before,
  it was given a second, `created_at`, column beside its own.

  **Migrating:**

  - Replace `created_at` with `inserted_at` inside `bookkeeping do ... end`.
    A declaration of `created_at false` becomes `inserted_at false`. To keep
    an existing column name, declare it: `inserted_at :created_at`.
  - Replace `created_at` in QuickView `fields:` lists, and anywhere else that
    names the attribute.
  - For a resource whose timestamp AshQuick generated, `mix ash.codegen` asks
    whether `created_at` is being renamed to `inserted_at`. **Answer yes.**
    Answering no generates a drop and an add, which loses every row's
    creation time.
