# Changelog

## Unreleased

### Bug fixes

- **A `validate match/2` refusal no longer crashes a QuickView form.** Its
  error always carries the `%Regex{}` as a var, and rendering the error called
  `to_string/1` on every var, so the LiveView died with
  `Protocol.UndefinedError` and the person never saw the message. Error
  messages now substitute only the vars they name, and render a var with no
  `String.Chars` through `inspect/1`. `AshQuick.Components.translate_error/1`'s
  default interpolation gets the same treatment.

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

- **The creation fields follow Ash's name: `inserted_at` and `inserted_by`,
  not `created_at` and `created_by`.** The bookkeeping DSL options and the
  default fields are renamed, so the declaration reads
  `inserted_at :inserted_at` / `updated_at :updated_at` /
  `inserted_by :inserted_by` / `updated_by :updated_by`. The timestamps match
  what Ash's `timestamps()` defines, and the actor relationship follows them
  so each pair reads alike. `AshQuick.Info.inserted_at_field/1` and
  `inserted_by_field/1` replace `created_at_field/1` and `created_by_field/1`,
  and the keys in `AshQuick.Info.bookkeeping/1` are `:inserted_at` and
  `:inserted_by`. A resource already calling
  `timestamps(always_select?: true)` now satisfies the defaults; before, it
  was given a second, `created_at`, column beside its own. The details header
  still reads "Created by X on Y".

  **Migrating:**

  - Inside `bookkeeping do ... end`, replace `created_at` with `inserted_at`
    and `created_by` with `inserted_by`. A declaration of `created_at false`
    becomes `inserted_at false`, and likewise for `created_by`. To keep an
    existing name, declare it: `inserted_at :created_at`,
    `inserted_by :created_by`.
  - Replace `created_at`, `created_by` and `created_by_id` in QuickView
    `fields:` lists, `load`s, filters, policies, and anywhere else that names
    them. A resource with a `postgres do references do ... end end` entry for
    `:created_by` renames it to `:inserted_by`.
  - For fields AshQuick generated, `mix ash.codegen` asks whether
    `created_at` is being renamed to `inserted_at`, and `created_by_id` to
    `inserted_by_id`. **Answer yes to each.** Answering no generates a drop
    and an add, which loses every row's creation time or creator. The
    `created_by_id` rename also drops and re-adds its foreign key constraint
    under the new name, which codegen flags as destructive; the data is kept.
