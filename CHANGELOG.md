# Changelog

## Unreleased

### Features

- **Stored attachments can be removed one by one, and an array of them has a
  real widget.** An `{:array, :attachment}` attribute on a form now renders as
  a card: a row per stored file (its preview and name) with a ✕, over a drop
  zone that states the upload's limits (files at a time, size, extensions).
  The ✕ pushes `"remove-attachment"` with the field and the row's position,
  and the form drops that position from the list it holds on the server. The
  list never travels through the page, so the browser can only say which
  position to remove. Stored rows stay up while a pick is uploading. The rows
  and the zone are public as `AshQuick.Components.attachment_row/1` and
  `AshQuick.Components.attachment_dropzone/1`, so a host with a richer row
  (alt text, a featured flag) can keep its own and reuse the zone. A removed
  file stays in the bucket, as a replaced one already did.

- **Attachments can be PDFs.** `AshQuick.AshTypes.Attachment` takes a third
  media class, `:document`, in `accepts:`. A field that accepts it offers
  `.pdf` in the picker and saves the value with `file_type: :document`. A
  servable document renders as a link to it, opened in a new tab, instead of
  an `<img>`. While the host is holding it, the usual placeholder renders.
  Whether the browser shows the PDF or downloads it is up to the host,
  through the headers it stores on the object. AshQuick does not look at the
  bytes, so a host that accepts documents should check them behind the
  `AshQuick.Storage` lifecycle callbacks.

### Bug fixes

- **A widget on a relationship path no longer crashes on an empty
  relationship.** `{[bill_of_sale: :display_name], widget: ...}` raised a
  `BadMapError` on the details page and in the list when `bill_of_sale` was
  `nil`, because the lookup tried `Map.get(nil, :display_name)` before its
  `nil` case. The widget is now handed `nil`, as a field without a widget
  already rendered blank.

- **An upload on an update form adds to an array of attachments.** The first
  pick on an `{:array, :attachment}` attribute replaced every file the record
  already held, because nothing on the page carried the stored list and the
  upload was folded onto nothing. The form now starts from the record's list,
  so uploads append. A host that relied on an upload replacing the list gets
  append plus a ✕ per file instead. An `add_*` argument the action folds onto
  an attribute is unchanged: it is never seeded from the record. A single
  `:attachment` field still takes the last file picked.
- **A posted value can no longer set an array of attachments.** A hand-sent
  `validate` or `save` carrying `form[<field>]` for an `{:array, :attachment}`
  attribute won over the list the form held, and was saved. The type checks
  only the visibility prefix, so a `private/` key belonging to another record
  was accepted, and the details page would have signed a URL for it. The
  posted value is now dropped and the server-held list is used. No input
  renders for the field, so no honest post contained it.
- **A form with nothing but uploads can be saved.** Its submit posts no
  `form` params, since a file input's value never travels with the form, and
  the event fell through to the host's `handle_event/3` and took the page
  down. It is now saved as an empty form plus the uploads.

- **Live updates reach records behind a join row.** The live-update walk
  stopped at any record without an `:id`, so a join resource keyed by the two
  ids it joins (a user's organization memberships) hid the records behind it:
  renaming an organization never refreshed the user's page, and `explain/1`
  said nothing about the memberships it passed over. The walk now names such a
  record by its primary-key values, follows its relationships, and counts it
  under `:skipped`. Only records with an `:id` are watched.

- **A single attachment field shows whether the file is ready.** A field
  holding one attachment rendered without asking the host for the file's
  state, so it showed the file as ready while the host was still processing
  it or had rejected it: a broken image, or a link to nothing. It now shows
  the Processing or Rejected placeholder, as a field holding several
  attachments already did.
- **Derived bulk actions report the rows they did not write.** Activate,
  Deactivate and Delete from the bulk menu could write fewer rows than were
  selected, for example skipping a row that changed since the page loaded,
  and still report success: the other rows were committed, the selection was
  cleared, and nothing was said. They were skipped silently. The page now
  compares the rows written with the rows selected, shows an error naming how
  many were applied, and keeps the rows that were not written selected so
  they can be checked and retried.
- **A failed form save no longer logs what was submitted.** A save the action
  refused (a validation, a stale record, a policy) logged the whole
  `AshPhoenix.Form` — params, changeset, record and actor — or the error
  struct carrying the submitted value, at `:warning`, so every validation
  failure put whatever was typed (email addresses included) into log storage.
  It is now one `:debug` line naming the resource, the action and what failed:
  the field names, or the error modules when no field is to blame. Values are
  never logged. If you relied on seeing these at `:warning`, raise the level
  for `AshQuick.LiveView.FormUtils` to `:debug`.
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

- **The version counter is no longer writable by actions.** The `:version`
  attribute versioning adds is now `writable?: false`, so an action with
  `accept :*` no longer takes a submitted `version` and writes it in place of
  `current + 1`. Only the lock moves the counter. The database column is
  unchanged, so no migration is needed.

  **Who is affected:** a resource that defines the counter itself. The
  versioning verifier now refuses one without `writable?: false`, and its
  message says so. Add the option to the attribute. A host that set `version`
  through an action was bypassing the lock's bump and should stop.

- **`:tower` is now a required dependency.** It was optional, and in a host
  without it the errors a page could not explain went to `Logger.error`
  instead. They now always go to Tower, through `Tower.report_exception/3`
  (or `Tower.report/4` for an error that is not an exception), and are not
  logged by AshQuick as well.

  **Who is affected:** a host that did not depend on `:tower`. It now gets
  Tower's application started at boot, and with it:

  - Tower's `:logger` handler, which reports every process crash to Tower's
    reporters, and any log event at Tower's `log_level` (`:critical` by
    default) or above;
  - Tower's telemetry handler for `[:oban, :job, :exception]`, which reports
    failing Oban jobs if the host runs Oban;
  - the `uuid_v7` package, and OTP's `:inets` application.

  Tower's default reporter, `Tower.EphemeralReporter`, keeps the last 50
  events in memory and sends them nowhere. A host that leaves it in place
  loses every error a page could not explain, where it used to have them in
  its log.

  **Migrating:** name a reporter that delivers them, each a package of its
  own (see [Tower's reporters](https://hexdocs.pm/tower/Tower.html#module-reporters)):

  ```elixir
  config :tower, reporters: [TowerSentry]
  ```

  `mix ash_quick.check` now reports `unconfigured_error_reporter`, a defect,
  while `:reporters` is Tower's default. `reporters: []` (for a test
  environment, say) is not reported. `mix igniter.install ash_quick` writes the
  default as a placeholder in `config/config.exs` when no `:reporters` is set.
  A host that already depended on `:tower` and configured a reporter has
  nothing to do.

- **The IP on audit rows and browser sessions is now the peer address by
  default.** It used to be the first entry of `X-Forwarded-For` (or
  `X-Real-IP`) when either was present. That entry is whatever the client
  sent, so anyone could choose the address recorded against them, even behind
  a proxy. Where the address comes from is now one setting,
  `config :ash_quick, client_ip: ...`, read at connect time: `:peer` (the
  default), `{:header, name}` or `{module, function, args}`. See
  `AshQuick.Config.client_ip/0`.

  **Who is affected:** an app behind a reverse proxy records the proxy's
  address on every audit row and browser session until it sets `:client_ip`.
  A controller building its scope from `conn.remote_ip` records the proxy's
  address even then: build it from `AshQuick.ClientIp.from_conn/1` instead, so
  controllers and LiveViews read the address the same way.

  **Migrating:** have the proxy overwrite a header with the client's address,
  and name that header. With Caddy:

  ```
  reverse_proxy app:4000 {
      header_up X-Real-IP {client_ip}
  }
  ```

  ```elixir
  config :ash_quick, client_ip: {:header, "x-real-ip"}
  ```

  If something sits in front of Caddy (a WAF, a CDN), list it in Caddy's
  `trusted_proxies` so `{client_ip}` is the real client rather than that
  proxy. AshQuick reads the header's last entry and does not walk a chain of
  proxies; that is the proxy's job. For a single nginx proxy, the header is
  `proxy_set_header X-Real-IP $remote_addr;`.

  **Name a header only if nothing but the proxy can reach the app.** Whoever
  can reach the app directly can set the header to any address they like.

  A bad `:client_ip` raises only once something connects. Assert
  `AshQuick.ClientIp.config_violations/1` is empty in a test to catch it before
  a deploy.

- **Writes with no actor are now audited.** A create, update or destroy with
  no actor (a background job, a scheduled task, an integration) used to leave
  no audit row at all. It now records one with `actor_id: nil` and
  `real_actor_id: nil`, and `attributes`, `arguments`, `changes` and `context`
  as for any other write. To say what made the write, name it under
  `action_source` in the action's context
  (`context: %{action_source: "nightly_sync"}`); it is kept in the row's
  `context`. That key is a convention, not a requirement, and is worth setting
  on writes with an actor too, such as an import. Other top-level string or
  atom values are kept as well; nested values are not.

  **Migrating:**

  - The store's `actor_id` and `real_actor_id` must accept `nil`.
    `AshQuick.Audit.Verifier` now refuses to compile an audited resource whose
    store has `allow_nil?: false` on either (a plain attribute or the source of
    `belongs_to :actor` / `belongs_to :real_actor`), or whose `:create` takes
    either through an argument with `allow_nil?: false`. Stores generated by
    `mix igniter.install ash_quick` with an actor resource already allow it.
    Stores generated without one declared
    `attribute :actor_id, :uuid, allow_nil?: false` and need the fix: set
    `allow_nil? true` on the attribute (or on the `belongs_to`), then run
    `mix ash.codegen allow_nil_audit_actor` and migrate. `real_actor_id` was
    never `nil` while there was an actor, so a hand-written store may refuse it
    too; it gets the same fix. In Postgres,
    dropping NOT NULL is a catalog change and does not rewrite the table.
  - A host that passed no actor on purpose to keep a write out of the log
    should name that action in `exclude_actions` instead, or turn audit off
    for the resource. Passing no actor is no longer a way to skip a row.
    Expect more rows from background jobs and other writes with no actor.
  - Code that reads the log and assumes every row has an actor will now see
    rows without one: loading `:actor` returns `nil` for them, and a report
    that inner-joins audit rows to users drops them.
  - An actor that is present but has no readable id (an atom, a map, a struct
    with no `:id`) still raises `AshQuick.Audit.ActorError`, as before. Only a
    `nil` actor changes behaviour.

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
