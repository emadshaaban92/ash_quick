# Changelog

## Unreleased

### Bug fixes

- **A QuickView list is no longer re-rendered on every event.** Assigns made
  during a render are never stored on the socket, so change tracking marked
  every one of them changed every time, and each event re-rendered whatever
  read them — every row included, only for LiveView to find that no row had
  changed. Rendering for an in-page event (ticking a row, opening a row's
  menu) is now 2–7× cheaper on the server. The diff sent to the browser
  shrinks by a few hundred bytes at most, since the pager is no longer
  re-sent: up to about 55% on a small page, about 2% at 100 rows. Rows were
  never re-sent, since keyed comprehensions already compare each row with
  what the client holds. Two places did this:

  - The generated `render/1` computed `:id`, `:fields`, `:path_for_page`,
    `:new_click` and the action menus on each render. Every row's cells read
    `@fields`, so every row was rebuilt. These are now assigned in
    `handle_params/3` (inside `QuickView.do_handle_params/4`, before
    `after_handle_params/2`), where they count as changed only when the URL
    changes them. A custom `render/1` or `after_handle_params/2` now sees them
    on the socket as well.
  - The list view assigned `:rows`, `:meta`, `:current_page`, `:pages_count`
    and `:filtered_actions` the same way, so the pager and the bulk actions
    menu were re-rendered on every event. The template now derives them inline
    from `@data`, `@params` and `@actions`, and they are re-rendered only when
    one of those changes.

- **A `validate match/2` refusal no longer crashes a QuickView form.** Its
  error always carries the `%Regex{}` as a var, and rendering the error called
  `to_string/1` on every var, so the LiveView died with
  `Protocol.UndefinedError` and the person never saw the message. Error
  messages now substitute only the vars they name, and render a var with no
  `String.Chars` through `inspect/1`. `AshQuick.Components.translate_error/1`'s
  default interpolation gets the same treatment.

### Breaking changes

- **`AshQuick.LiveView.QuickView.prepare_assigns/4` is gone.** It computed the
  list, details and form assigns inside the generated `render/1`; they are now
  assigned on the socket by `QuickView.do_handle_params/4` (see above). What
  remains is an internal `prepare_assigns/3` (`@doc false`) that takes the
  socket, and is not meant to be called by a host.

  **Migrating:** a QuickView with its own `render/1` that called
  `QuickView.prepare_assigns(assigns, assigns.params, assigns.ash_action,
  options)` should drop the call. The same assigns are already on the socket by
  the time it renders. A host that overrides `handle_params/3` gets them as
  long as it still calls `QuickView.do_handle_params/4`.

- **`AshQuick.LiveView.Components.ListView.list_view/1` takes the page as
  `data`.** The `rows`, `row_id` and `meta` attributes are gone, and `data`
  (the page `keep_live/4` reads, with its `results`, `count`, `limit` and
  `offset`) is required. The rows and the pager are both read from it. The
  branch that accepted a `%Phoenix.LiveView.LiveStream{}` as `rows` is gone
  too. The component also reads `@actions` directly where it used to read
  `assigns[:actions]`.

  **Migrating:** a host that renders `<.list_view>` itself should pass the
  page as `data={@data}` and drop `rows`, `row_id` and `meta`. A stream is not
  accepted: pass the page itself. A host that calls `ListView.list_view/1` as
  a plain function, with a map rather than through `<.list_view>`, must put an
  `:actions` key in that map, `nil` if there are none.

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
