# Changelog

## Unreleased

### Features

- **A details page links its writers.** The "Created by X · Last updated
  by Y" header names each writer as a link to their details page, for a
  reader the nav's access control grants that page, and as plain text for
  anyone else. Two new `display` options say how:

  ```elixir
  ash_quick do
    display do
      label :name
      hint :email
      path "/users"
    end
  end
  ```

  `hint` names an attribute, calculation or aggregate that tells two
  records sharing a label apart; it is plain text, shown as the writer's
  tooltip to every reader who may read the field, and absent where a field
  policy hides it. `path` is the base path of the QuickView a record opens
  at, `<path>/:id`, used only where the router serves that resource's
  details page there. Left out, it is the one QuickView with a details
  route the router serves the resource at, so most resources declare
  nothing. `AshQuick.Nav.Info.details_path/2` and `details_paths/3` resolve
  records' pages for a scope, for a custom page linking them.
  `mix ash_quick.check` reports a declared path that is not the resource's
  details page (`:unrouted_display_path`), and, as advisory, an actor
  resource served at two with none declared (`:ambiguous_display_path`). A
  hint naming no such field does not compile, and neither does a path that
  is not `/segment`s with no trailing `/`.

- **A details page opens an attachment field's images at full size.** On
  the built-in details page, a servable image in an `:attachment` or
  `{:array, :attachment}` field is a button that opens a dialog showing it
  as large as the screen allows, with previous and next (and the arrow keys,
  following the reading direction) through the field's other images, and a
  link to the original in a new tab. The dialog is announced by the field's
  label, and fetches each original only when its slide is first shown. An
  image the host is still holding or refused, a video and a document open
  nothing, as before; a field drawn by a widget is left to it. The dialog is `AshQuick.Components.attachment_viewer/1`,
  which a custom page uses directly: its previews open it when given its id
  as `viewer`, wherever they sit on the page, and its `caption` slot says
  more about each image than its file name. Its hook is colocated, so a host
  already bundling `phoenix-colocated/ash_quick` needs nothing new.
  `AshQuick.AshTypes.Attachment.Value.display_name/1` names an attachment the
  way the previews do.

- **The list's Advanced filter has more operators.** Is Empty and Is Not
  Empty, on any field that can be empty and that the actor sees on every row
  (a blank string counts as empty); Any Of, picking several values of a
  fixed set (an `Ash.Type.Enum`, or an atom with `one_of`); Ends With and Not
  Contains, on strings; and On Day, on timestamps, keeping a whole day as the
  list shows it, in `AshQuick.Config.timezone/0`. Ends With is Ash's
  `string_ends_with`, so it works on every data layer. Not Contains leaves
  out a row whose field is empty, as Ash reads it; Is Empty finds those.
  Each reads on its chip ("Note is empty", "Stage is any of Draft, Live"),
  and a row's value follows it to an operator that takes one the same way.
  A link's Any Of on a field without a fixed set shows its values typed in,
  comma-separated, and a link's Is Empty on a field hidden on some rows is
  dropped with the refused-filter flash, since Ash reads a hidden value as
  `nil`.

- **The list shows its applied filter as chips.** Above the table, each
  top-level row of the Advanced filter is a chip ("Price > 10", "Active =
  Yes"), naming the field as its column does and reading the value as a
  column without a widget shows one (an enum's label, a timestamp in the
  list's zone); its ✕ drops that row, and "Clear all" drops the filter. A
  group of rows is one "All of 3 conditions" or "Any of 3 conditions" chip
  that opens the modal. The Advanced filters button carries the number of
  rows the list is filtered by. Rows without a value, and rows dropped
  before the read, have no chip and are not counted.

- **The list's filter names a value its field cannot take, under its row.**
  On Apply, each row's value is cast with its field's type, as Ash casts a
  filter's values; text in a number or a broken UUID shows the field's error
  ("is invalid", through `:error_translator`) under that row, and nothing is
  applied until it is fixed. Before, the data layer refused the whole filter
  and the list came back unfiltered under a flash naming no row. A link
  carrying such a value is still read once more without its filter, with
  that flash.

- **A list sorts by a column's header.** A click sorts the list by that
  column ascending, then descending, then back to the default order; the
  column goes ahead of `sort_by` and the action's own sort, which still break
  its ties. One column at a time, in the URL as `?sort=name` or
  `?sort=-owner.name`, kept while paging, searching and filtering, and
  followed by the export. Every list column Ash sorts in the data layer is
  sortable by default (public attributes, aggregates, expression
  calculations, also through public to-one relationships; `sortable? false`
  opts one out); `list: [sortable: ...]` names exactly which, so a large
  table offers only its indexed columns, and `sortable: []` turns sorting
  off. Entries are checked when the QuickView compiles, and a `?sort=` naming
  another column is dropped.

- **AshQuick's own flashes are translated.** "Record saved successfully",
  "Record deleted successfully", the stale-record, not-found, refusal and
  generic error sentences, the refused-filter and failed-print flashes, the
  bulk run's skipped-rows count, the upload errors, the export and Live Users
  flashes and the Live Users page title now go through `AshQuick.Gettext`,
  with Arabic translations. A test fails when a locale's `.po` lacks a
  message, leaves one empty in any plural form, marks one fuzzy, or names a
  binding the English does not, so a message merged without a translation
  no longer ships in English with CI green.

- **Each field on a details page names itself.** A details row carries
  `data-field` with the field's path, `.`-joined for a relationship path
  (`[vehicle: :chassis_number]` is `"vehicle.chassis_number"`), so a test can
  assert on one field with
  `assert_has(~s([data-field="name"] dd), text: value, exact: true)` instead
  of matching rendered HTML. The name is
  `AshQuick.LiveView.QuickField.data_field/1`, public for a custom details
  template to put on its own rows.

- **A list's page size can be picked from the page.** A "Rows per page"
  select beside the footer's count offers the list action's `default_limit`,
  then each of 10, 25, 50, 100 and 250 that is at least twice it and within
  its `max_page_size` (a default of 20 offers 20, 50, 100 and 250); a
  `?limit=` that is none of those is listed too, so the select shows the size
  the page reads at. Picking one writes `?limit=` and goes back to the first
  page, and picking the default drops it from the URL. The select is left out
  when no pick would change the page: the default is the only size, or every
  row fits on the smallest one.

- **An action's change can tell a QuickView form being built, validated or
  submitted.** Every changeset a QuickView form builds carries
  `AshQuick.form_stage_key/0` (`:ash_quick_form_stage`) in its context:
  `:build` once as the form opens, `:validate` on every `phx-change` or upload
  after that, `:submit` when it is submitted, a bulk action's run included.
  Read it with `AshQuick.form_stage/1`, and compare with
  `AshQuick.form_build_stage/0`, `AshQuick.form_validate_stage/0` and
  `AshQuick.form_submit_stage/0`. Any other caller leaves it unset, so a change
  can seed an argument when the form opens without filling it in for a caller
  that left it out, or again once the person cleared it. Whatever the build
  sets on the action's inputs becomes the form's initial params. The run's
  `action_source` is `AshQuick.form_source/0` as before, and building or
  validating a form still carries none.

- **A field with a fixed set of values is picked from a select.** That is an
  `Ash.Type.Enum`, or an atom with `one_of`, or an `Ash.Type.NewType` over
  either; an enum used to get a text input. One value is picked from a
  select, a list of them from a multi-select; the list's filter offers the
  field with `=` and `!=` over a select of its values; and the selects, the
  filter, the list and the details page all show the same label for a value:
  an enum's own `label/1`, string-valued enums included, or an atom's value
  humanized. Typing into a select now matches the labels it lists, anywhere
  in them and in any case, rather than the start of the stored value, so
  `extra_` no longer finds `:extra_large` ("Extra Large"). An atom without
  `one_of` gets a text input instead of a select with nothing to pick, which
  raised.

- **A refused run says why, in the policy's words.** A policy's
  `error_message` is now what a run it refuses flashes, from a form, a
  confirmation or a bulk action, translated through `:error_translator` like
  Ash's own messages; a policy with none still says "You don't have permission
  to do that." Only the message is shown, never the policy breakdown. An
  `error_message` function that returns its own exception, and a refusal the
  page can see coming (a hidden action, a forged event), keep the fixed
  sentence.

- **Ash's error messages in a flash are translated.** They go through
  `:error_translator`, as the same messages next to an input already did,
  instead of plain interpolation. `mix ash_quick.install` prints `mix
  ash.gen.gettext --domain errors`, which copies Ash's messages into the
  catalogue a Phoenix `translate_error/1` reads. A var a translator could not
  render (the `%Regex{}` a `match/2` error carries) reaches it already rendered
  through `inspect/1`.

- **A form finds the relationship an id-list argument edits from its
  `manage_relationship` change.** An `{:array, :uuid}` argument gets its
  multi-select dropdown, its prefill on update and its loaded labels from the
  relationship a `manage_relationship` change on the action, or failing that a
  global one covering it, names for it, so it may be called anything. An
  argument no such change names still edits the relationship its
  `<relationship>_ids` name spells, as before.
  `AshQuick.LiveView.Utils.argument_to_relationship/2` is now `/3`, taking the
  action.

- **A print renders through a renderer the host may replace.**
  `config :ash_quick, pdf_renderer: MyApp.PdfRenderer` names an
  `AshQuick.PdfRenderer` that turns a print template's output into the PDF
  the browser gets; `AshQuick.PdfRenderer.ChromicPDF` is the default. A test
  suite with no Chrome names one that hands back the template's HTML and reads
  what each print says off the pushed `"ash_quick:pdf"` event. A host naming
  its own renderer does not need ChromicPDF for its prints to compile.

- **Bulk actions run through the action modal.** A bulk action opens the
  modal over the list, which keeps its selection: an action that takes no
  input asks for confirmation, naming how many rows it applies to; one that
  takes input opens a form whose values apply to every selected row. The form
  checks the values themselves as they are typed, and the run refuses what
  depends on a record, keeping the modal open with what was typed and the
  error worded as a form's is. A row the run did not write stays selected and
  is reported. `list: [bulk_actions: ...]` now takes action names beside custom
  items, as a list or a function of the socket; a list is checked when the
  QuickView compiles.

- **The action modal shows the action running, and can't be left mid-run.**
  From submit until the answer, Save or Confirm shows a spinner over its
  label, the ✕ and Cancel are disabled, and the form's controls are locked:
  LiveView disables its buttons and makes its text read-only, the library's
  inputs, selects, checkboxes, dropdowns and drop zones ignore the pointer, and
  a colocated hook on the form refuses the keys and clicks that would still
  change a checkbox, a radio, a select or a searchable dropdown. A refused run
  unlocks the modal with its values kept. Cancel, and a list field's Add and
  ✕, are now buttons rather than links, so LiveView disables them and the
  keyboard can't reach them either. A custom action template gets the ✕ for
  free; its own `<.form>` and markup opt in, as the
  `AshQuick.LiveView.QuickView` docs describe.

  Hosts register the hook: `import { hooks as ashQuickHooks } from
  "phoenix-colocated/ash_quick"` and spread `...ashQuickHooks` into the
  LiveSocket's `hooks`. The styling hangs on the host's `phx-submit-loading`
  Tailwind variant, which a new Phoenix app defines. The installer adds both
  when they are missing.

- **Actions open in a modal over the page they were opened from.** A create,
  an update or a destroy renders in a modal over the list or details the
  visitor was on, kept at its search, filters and page; a URL reached directly
  opens over the record's details, or the list for a create. Closing it, or
  saving, returns to that page — so an update run from a searched list lands
  back on that list rather than on the record's details. A create still goes
  to the record it made, and a destroy opened over the record it destroyed goes
  to the list.

  An action that takes no input opens the same modal as a confirmation (Cancel
  / Confirm) instead of a `data-confirm` browser dialog, and a destroy is
  routed at `/:id/:action` like an update. Every action now runs through the
  modal, stamped `AshQuick.form_source/0`: a row action no longer runs on the
  click, stamped with its surface. A policy scoped
  to a surface still decides which controls are drawn, but no longer refuses a
  run. A host whose surface-scoped policy was the only thing refusing an action
  without inputs needs a validation there, as a form with inputs already did —
  or a `forbid_if context_equals(:action_source, :ash_quick_form)` where
  QuickView must not run the action at all, as the impersonation docs now show.

  Tests that selected the action's form as `"form"` now also match the forms
  on the page underneath; select `"#ash-quick-action-modal form"`. Running an
  action without inputs takes a submit of that form after the click.

- **An action prints.** `change {AshQuick.Print, template: MyTemplate,
  delivery: :print}` on an action makes it print wherever AshQuick runs it: a
  row action, a bulk selection, the details page or the action's form. The
  change marks the records the action returns; what it wrote goes to the
  template's `render/1` in one call, in the order the rows were selected. The
  render runs after the action has committed, so the action's transaction
  holds its locks only for its own writes; a render that fails keeps what the
  action recorded and flashes that the PDF could not be produced. The PDF reaches the
  browser over the LiveView socket: `delivery: :print` opens the print dialog
  on it from an off-screen frame, `:download` (the default) saves it. Nothing
  is uploaded and no link is handed out. The host calls `initPrinting()` from
  `assets/js/print.js` once in its `app.js`. The action's button is its own,
  shown where `Ash.can?` allows it like every other.

  On a resource carrying the `AshQuick` extension, a print that could not
  work does not compile: one on a destroy action (which returns no record to
  print), one whose options the change refuses, or one in an application
  without ChromicPDF.

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

- **Every storage lifecycle callback is told who is asking.**
  `object_states/2` and `object_referenced/4` take an `opts` list carrying the
  request's `:scope`, as `object_arriving/2` already did. A host can now read
  states as the person viewing the page and record a reference as the person
  who saved, instead of as nobody or a platform bot. Pass `scope:` to
  `AshQuick.Storage.states_for/2` (and to `url_for/2` when it looks states up
  itself); AshQuick's own list, details and form surfaces pass the page's
  scope, and so does the save. A storage module that exports only the older
  `object_states/1` or `object_referenced/3` is still called with them, so
  nothing has to change on upgrade. List and details widgets now receive
  `@scope` in their assigns.

### Bug fixes

- **The filter's ✕ waits while Apply runs.** The Advanced filters and
  export modals now use the same modal as an action's form, so the filter's
  ✕ is swapped for a disabled twin while Apply submits, as the action
  modal's is. Before, a ✕ clicked then patched with the params from before
  the filter and could land after Apply's patch, undoing it. Every modal's
  ✕ now sits at the end of the line in a right-to-left locale too.

- **The Advanced filters and export modals close only by their ✕ (and
  the filter's Cancel).** A click on either backdrop closed it, unlike the
  action modal, so a stray tap beside the filter (easy on a phone) threw
  away a filter half built. Both backdrops are gone, both ✕ buttons are
  labelled Close, and each dialog is named by its heading for screen
  readers. The filter gains a Cancel button between Apply and Reset,
  which closes the modal and leaves the filter applied before as it was;
  Reset, which clears the filter, now reads in the error colour.

- **The list's Starts With filter works on every data layer, and reads `%`
  and `_` as themselves.** It was a SQL `LIKE`, which only AshPostgres
  defines, so on ETS or any other data layer the read was refused and the
  filter dropped; on Postgres a `%` or `_` in the value matched anything. It
  is now Ash's `string_starts_with`, which AshPostgres escapes. A filter link
  written before still reads the same.

- **A timestamp in the list's filter is read in the zone the list shows it
  in.** The `datetime-local` input names no zone, and Ash cast its value as
  UTC, so with `config :ash_quick, timezone: "Africa/Cairo"` a filter for
  "after 10:00" kept rows from 13:00 on. The filter now holds the UTC instant
  the typed time means in `AshQuick.Config.timezone/0`, and shows it back in
  that zone. A filter link written before, holding a time with no zone, is
  still read as UTC.

- **The list's filter leaves out fields the actor may not see.** A field a
  field policy hides on every row was still offered; Ash read it as `nil`, so
  the filter returned nothing and looked like an answer. A row naming such a
  field, from a link written for someone else, is dropped before the read,
  with the refused-filter flash, and the address bar is corrected. A row
  naming a field the form does not offer at all, such as a list, shows that
  field in its select rather than the first one offered. A new row starts
  on the first field offered rather than on `id`, which a resource may not
  offer, and the boolean choices read "Yes" and "No", translated (Arabic
  «نعم» and «لا»).

- **A boolean reads "Yes" or "No" on the list and the details page.** It was
  humanized as the atom it is, "True" or "False", in English whatever the
  locale, while the filter above it offered "Yes" and "No". It now reads the
  same translated words. Exports still write `true` and `false`.

- **A 404 details page wakes for its record however the URL spelled the id.**
  A details page whose record was not found listens for it on the id from the
  URL, which it used as typed, so `/products/<UPPER-CASED UUID>` listened on a
  topic nothing publishes to and never noticed the record appear. The id is
  now cast through the `:id` attribute's type first; one that does not cast
  listens on nothing.

- **A refused list filter is logged without its values.** The warning logged
  when a URL's custom filter makes the read raise named the whole filter,
  values included, and the data layer's error, which quotes the value back. A
  filter on an email column put that email in the log, and an
  `InvalidFilterValue` went on to inspect the whole query, the actor's email
  included. It now names the filtered fields, and for each error its kind,
  the start of its message on one line with the filter's values redacted, and
  the frames it was raised at.

- **A private `:create` gets no New button.** The list offered New whenever
  `:create` was routed and its policies allowed it, but the create page only
  reaches a public action, so a private `:create` led to a page that refused
  it. The button now also asks that the action be public.

- **A confirmation and a bulk action's row count read in Arabic.** "Cancel",
  "Confirm" and "Applies to %{count} selected rows." were missing from the
  gettext catalogue, so they showed in English in every locale. The catalogue
  is extracted again (dropping the print modal's messages, whose component is
  gone), and CI now fails when it falls behind the code.

- **Without Localize, dates and datetimes read as dates and times.** A host
  without the optional `localize` dependency got `format_datetime/1` as
  `26-03-04-05-06-07` and `format_date/1` as `26-03-04`: a two-digit year, and
  a time whose fields read as more of the date. They now read
  `2026-03-04 05:06:07` and `2026-03-04`. Export and print file names keep
  their dashed stamp.

- **Dates and times read as formatted on the list and the details page.** A
  `:date`, `:time` or `:naive_datetime` field printed as ISO 8601
  (`2026-10-19`) where a `:utc_datetime` read as `AshQuick.Config` formats it
  (`Oct 19, 2026, 7:54:10 PM` with Localize). Each now reads the same way: a
  date as `AshQuick.Config.format_date/1` (`Oct 19, 2026`), a time as
  `format_time/2` with seconds, and a naive datetime as `format_datetime/1`,
  which now takes one and leaves it unshifted, since it names no zone; so does
  a `Time` passed to `format_time/2`. An export writes times and naive
  datetimes the same way, as it already did dates and datetimes.

- **A list reached through `?action=` keeps working past its first page.** A
  list other than the page's default, opened at `?action=<read>`, wrote its
  pager, search, filter and custom-filter links as `<base>/<read>`, which the
  router serves as a record page, so every one of them led to a 404. A link
  for an action with no record id other than `:create` now names the action
  in the query over the base path, `<base>?action=<read>&page=2`, and the list
  stays the one named. A second create action, at
  `<base>/create?action=<create>`, is reached as before.

- **A failed save says why, sub-forms included, and is called a refusal only
  when it is one.** An error from a nested form, such as an item of a
  `manage_relationship` argument whose own create refuses a value, is filed at
  the item's path (`[:items, 0]`), and the form only looked at its root for
  input errors. Finding none, it took the failure for a policy refusal and
  flashed "You don't have permission to do that.", as it did for any failure
  that named no input. The form now counts every sub-form's errors: each shows
  under its own input, and one naming a field its sub-form has no input for,
  or a sub-form under a field the actor cannot see, is flashed with the item it
  is about: `Items 2 › Note: is hidden`. A failure naming no input is worded as
  every other surface words it: a policy refusal in the policy's words, a
  missing record as missing, anything unexpected as the generic sentence,
  reported to Tower. (#78)

- **A form holding a sub-form built for a read no longer crashes its page.**
  Where a `manage_relationship` looks its records up (`on_lookup`) with nothing
  to create, AshPhoenix builds each item a post sends for the read action, and
  every place that asked the item's action for its fields raised a `KeyError`
  (a read accepts no attributes): drawing the form, folding uploads into a
  save, and wording a failed save. A read now offers no fields, so the item
  draws no inputs and its errors are flashed with the item. (#81)

- **A bulk print behind a `where:` prints exactly the rows it marked.**
  `change {AshQuick.Print, ...}, where: [...]` marks only the records that pass
  the condition, but the page read the first record's mark and printed every
  record the run wrote: a selection led by a row the condition excluded printed
  nothing, and one led by a row it passed printed the excluded rows too. The
  print is now of the marked records alone, in the order they were selected.

- **A destroy over its record's details reached by an upper-cased UUID goes to
  the list.** Whether the modal opened over the record it destroyed was decided
  by comparing the id in the details page's URL with the destroyed record's,
  as strings. An upper-cased UUID loads the record, since Ash casts it to
  lowercase, but is not equal to it, so the destroy patched back to the deleted
  record's URL and showed the 404 panel. It is now matched against the record
  the page showed.

- **A QuickView no longer offers or runs a private action.** Every list, menu
  and URL lookup used to walk all of a resource's actions, so an update or
  destroy declared `public? false` was offered on each row, an input-less one
  was derived into the bulk menu, and any of them could be reached by naming
  it in `?action=`, in `/:id/:action`, or in a hand-sent `"row_action_click"`
  or `"bulk_action"` event. Ash's documentation says no extension may expose a
  private action, and the policy it recommends for them,
  `bypass private_action?() do authorize_if always() end`, lets every call to
  one through, so such a page ran internal actions for anyone who named them.
  Pages now list and resolve public actions only, and an event's action name
  is matched against the update and destroy actions the page could have
  offered instead of being looked up on the resource. A name that matches
  none is refused with the usual flash. `list: [default_action: ...]` and
  `details: [default_action: ...]` may still name a private read, since the
  host chose it in code. `mix ash_quick.check` and the dropdown checks at
  compile time skip private actions too.

- **A field a field policy hides no longer crashes the page.** Ash reads it
  back as `%Ash.ForbiddenField{}`, which HEEx cannot render, so one policy on
  a listed column took the list or details page down for everyone it hid the
  column from. A hidden value now renders as a muted dash with a "Hidden"
  label for screen readers, and a list or details `widget:` is never handed
  one. A column hidden on every record (`Ash.can_see_fields/4` says the actor
  can never see it) is left out of the list, the details page and the CSV
  export. A column whose policy depends on the record stays, and shows the
  mark on the rows it is hidden on. `AshQuick.LiveView.QuickField.resolve_value/2`
  passes a hidden relationship through instead of reading into it.

- **A select shows its error once a pick is taken back.** Clearing the
  relationship, atom or array-of-atom select, or removing its last tag, posts
  the same blank as a select never touched, so a required one said nothing
  until the save failed. The change event says which it was: LiveSelect fires
  it from the field's own hidden input, so its `_target` names the field. The
  form now marks that field in its params, and the select renders the mark as
  a hidden input, so every later post carries it, including the one that
  recovers the form after a reconnect. A select holding a stored value is not
  marked by a change to another field, so an error another field's change
  puts on it waits for the save. A host `widget:` for a select reads its
  errors with `AshQuick.LiveView.FieldErrors.for_select/1` and renders
  `FieldErrors.used_marker/1` beside it. `for_hidden_input/1` stays for
  attachments, where an array emptied by its ✕ still shows its error at once.

- **A tag select can be emptied on an edit form.** Removing the last pick
  from an array-of-atom or has-many select posts nothing under the field's
  name, only LiveSelect's `<name>_empty_selection` marker. The form read the
  field as absent and fell back to the value the record held, so every stored
  pick came back, no error showed, and a save kept the old list. A form now
  reads the marker as an empty list, on the root form and on any sub-form,
  before it validates or saves.

- **A form takes only the attachment keys it issued.** A single attachment
  round-trips through a hidden input, so an edited post could set its key to
  anything with the right visibility prefix, such as another record's private
  object. The page then signed a URL for it, as soon as the next render and
  after a save. The same held for an argument, an attachment inside an embed,
  and one on a related record's sub-form. A form now takes a key for a field
  only if the form held it in that field when it was built, or an upload on
  the page minted it. Keys the record held count only for their own field, so
  a key cannot move from a field the actor cannot write into one it can. The
  check reads what the type's cast made of the post, on the form and every
  sub-form, so it covers unions, typed maps and managed relationships as well.
  A field holding a key the form never issued goes back to the value the form
  held, with a warning naming the field. A host widget
  that signs uploads without `FormUtils.presign_attachment_upload/3` will see
  its keys dropped.

- **An attachment field shows the error its save failed on.** When an
  action's own validation refused an attachment field on a create form, such
  as `validate present(:signed_scan)` with nothing picked, a save made
  without any change event before it failed with nothing on the page saying
  why. The save leaves a field with nothing picked out of its params, and a
  field missing from them read as untouched, for the single field and an
  array alike. Both now show the error inside the field's section once the
  form has been submitted. The single field also no longer shows it on the
  first change anywhere in the form while nothing is picked: its blank hidden
  input no longer counts as a touch, which matches the array. The single
  field's hidden input no longer repeats the file input's id.

- **A list of nested forms shows the error its save failed on.** A create
  whose action needs at least one nested entry, saved with none added, posts
  nothing under the field, so the form read it as untouched and left its
  section empty; the error reached the page only as a toast, and not at all
  when the save failed on more than one field. The rule from the attachment
  fix above now lives in `AshQuick.LiveView.FieldErrors.for_field/2`: a
  field's errors show once the person has used the input or the form has been
  submitted. `AshQuick.Components.input/1`, the nested-form sections, the
  attachment widgets and the relationship and atom selects all use it. The
  selects no longer show a required field's error on the first keystroke in
  another field, before they were touched; a blank select counts as used only
  once the person has changed it (see above). A host whose
  `input/1` was generated by `phx.new` still decides on `used_input?/1` alone,
  so a custom template rendering the host's `<.input>` keeps the old gap.
  Swap its `errors = if used_input?(field) ...` line for
  `|> assign(:errors, AshQuick.LiveView.FieldErrors.for_field(field))`, which
  translates through the configured `:error_translator`; the example app's
  `CoreComponents` shows it. It is deliberately not in
  `AshQuick.Components`: every public function there is imported into every
  QuickView, so a new one breaks any host QuickView that calls a helper of its
  own by the same name. Adding a public function to `AshQuick.Components` is a
  potentially breaking change for hosts.

- **Clicking an attachment drop zone opens the file picker.** The zone's
  label pointed its `for` at the form field's id, while the file input inside
  it always carries the upload's ref as its id, so a click or a tap on the
  zone (or its "browse" link) reached nothing; only a drop worked.
  `AshQuick.Components.attachment_dropzone/1` no longer takes an `id`: its
  label now points at the upload's ref.

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

- **`AshQuick.Components` has a public `attachment_viewer/1`.** Every
  QuickView imports that module, so one defining its own `attachment_viewer/1`
  no longer compiles once it calls it unqualified: rename it, or call it by
  its module.

- **`mix ash_quick.check` reports every update and destroy a page cannot
  route.** `:unroutable_action` looked only at actions taking inputs, but since
  the action modal every public update and destroy, with inputs or without,
  opens at `<base>/<id>/<action>`. An input-less action behind
  `except: [:action]` or `only: [:index, :show]` showed a button leading to a
  404, and the check said nothing.

  **Who is affected:** a host running `mix ash_quick.check --strict` with a
  QuickView that serves no `/:id/:action` over a resource with public updates
  or destroys. Route `:action`, make the actions the page should not offer
  `public? false`, or record the path under `exempt: [unroutable_action: ...]`.

- **A QuickView refuses a form it could not save.** A list of scalars with no
  fixed set of values (`{:array, :atom}` without `one_of`, `{:array, :string}`,
  `{:array, :integer}`, ...) got one text input on the form, which posts a
  string the list refuses: it could never be saved, and an update form over a
  record already holding values crashed. A QuickView whose form would offer
  one, on any public create, update or destroy, no longer compiles, and the
  error lists every such field. A field a form widget renders is left alone.

  **Who is affected:** a page whose resource's public action takes such a
  field. Name its values with `constraints: [items: [one_of: [...]]]`, type its
  items with an `Ash.Type.Enum`, give the page a form widget for it, or leave
  it out of the action.

- **A list's page size is capped by its action, not by config.** `?limit=`
  is held to the list action's `pagination.max_page_size` (Ash's default is
  250), the same number Ash clamps the read to, so the offset, the footer and
  the pager agree with the rows. `config :ash_quick, max_page_size:` and
  `AshQuick.Config.max_page_size/0` are gone.

  **Who is affected:** a host that set `:max_page_size`. Drop the key and set
  `max_page_size` in the `pagination` block of each list action instead; a
  host that never set it sees no change, since both defaulted to 250.

- **A list opens at its action's `default_limit`.** A list nobody sized read
  20 rows whatever its action declared, so `pagination default_limit: 50`
  still opened at 20. It now reads the list action's `default_limit`, held to
  its `max_page_size`. A URL that names `?limit=` still gets that size, and
  every link back to the list leaves the action's default unsaid.

  **Who is affected:** a host whose list action's `default_limit` is not 20.
  Its list opens at that size now, so a `default_limit 250` reads 250 rows.
  Set `default_limit 20` in the action's `pagination` block to keep the old
  page.

- **A form shows each field error where it belongs.** An error on a field
  the form has an input for shows under that input, and only there; one with
  no input to show it (a field set by a change, not accepted, or restricted
  away) or about the record as a whole is flashed, a field error as `Field:
  message` ("Name: is required"). This used to depend on how many errors a
  save had: a single one was flashed as well as shown under its input, two or
  more showed under their inputs only, and one on a field with no input could
  fail the save without a word. The field was also left off a message starting
  with a capital letter, a guess that ran it into a sentence translated into a
  script with no capitals. A host test asserting a form's field error in the
  flash now finds it under the input. An error naming a var with no
  `String.Chars` (`must match %{match}`) shows the value under the input too,
  rather than its placeholder. An error with no message of its own reads
  "Price: is invalid", in the same shape. A custom form template is assumed to
  render an input for every field the action offers.

- **Every action runs through the action modal, stamped `:ash_quick_form`.**
  A row or details action no longer runs on the click, stamped with its
  surface: it opens the modal, and Confirm (or Save) runs it. A policy scoped
  to `:ash_quick_list` or `:ash_quick_details` now only hides the control; one
  that must refuse the run needs a validation, or
  `forbid_if context_equals(:action_source, :ash_quick_form)`. See
  "Actions open in a modal" above.

  **Who is affected:** a host whose surface-scoped policy was the only thing
  refusing an action without inputs, and tests that select an action's form
  as `"form"` (select `"#ash-quick-action-modal form"`) or expect an
  input-less action to run on the click (submit the modal's form after it).

- **The action modal's keyboard lock is a colocated hook the host
  registers.** Import `hooks as ashQuickHooks` from
  `"phoenix-colocated/ash_quick"` and spread it into the LiveSocket's
  `hooks`, and keep the `phx-submit-loading` Tailwind variant. Without them
  the modal still works, but shows no spinner and its controls still answer
  the keyboard while an action runs. The installer adds both.

- **A bulk action asks before it runs.** Clicking it in the menu opens the
  modal; Confirm (or Save) runs it. Tests click the action, then submit
  `"#ash-quick-action-modal form"`.

- **A bulk run is stamped `:ash_quick_form`**, not `:ash_quick_list_bulk`. A
  policy scoped to `:ash_quick_list_bulk` now only hides the menu item; one
  that must refuse the run needs a validation, or
  `forbid_if context_equals(:action_source, :ash_quick_form)`.

- **A page passing `bulk_actions` gets exactly that menu.** The derived
  actions are no longer added to it; name them (`[:activate, :destroy, ...]`)
  to keep them.

- **A destroy with arguments is no longer derived into the bulk menu**, as an
  update with inputs never was. Name it in `bulk_actions` to offer it.

- **`:print_templates` is gone, with the print menu and its modal.** A
  template prints through an action instead: give the resource an update that
  writes nothing (`manual fn changeset, _context -> {:ok, changeset.data} end`)
  carrying `{AshQuick.Print, template: MyTemplate}`. Prints get the action's
  policies and an audit row, and are no longer uploaded to storage.

- **Ash 3.37.1 and ash_phoenix 2.3.25 or later are required.** Column filtering
  uses `Ash.can_see_fields/4`, which arrived in 3.32.1 and from 3.35.0 no longer
  skips a policy authorizer that has not loaded yet. Live pages re-target their
  subscriptions through `keep_live`'s dynamic subscriptions, which arrived in
  ash_phoenix 2.3.20, and 2.3.25 fixed CVE-2026-82724 through CVE-2026-82727.
  Ash 3.37.1 fixed EEF-CVE-2026-114214. The other floors rose to the releases
  the suite runs against: spark 2.7 and phoenix_html 4.3, and for the optional
  features nimble_csv 1.3, exceed 0.7, ex_aws 2.7, ex_money 6.2, localize 1.4
  and sourceror 1.13.

  **Who is affected:** a host on an older release of any of these. Update
  them with `mix deps.update` alongside AshQuick.

- **A private action can no longer be reached from a page.** See the bug fix
  above.

  **Who is affected:** a host that relied on a QuickView to offer or open an
  update, destroy or create declared `public? false`. Make the action public
  if the page should offer it, and keep the authorization in a policy that
  refuses the actors who should not run it.

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
