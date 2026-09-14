defmodule AshQuick do
  @moduledoc """
  A Spark DSL extension for Ash resources that adds AshQuick features.

  ## Liveness

  Adding the extension wires the resource's PubSub publications. Every create,
  update and destroy is published on the resource's own topics —
  `"product:<id>"` and the bare `"product"`, both from `AshQuick.Topics` —
  through the endpoint configured as `:endpoint`. A QuickView derives what it
  subscribes to from the same functions, so a page cannot listen on a topic the
  resource does not publish.

  `enabled?` is therefore the whole switch: a QuickView is live exactly when its
  resource publishes, and the view declares nothing. `enabled? false` keeps the
  extension for its other features and leaves those pages static — the right
  answer for an append-only resource, whose new rows a refetch could not show
  anyway.

      ash_quick do
        liveness do
          enabled? true       # the default
          prefix "products"   # an override; defaults to the resource's short_name
        end
      end

  The prefix is owned here rather than borrowed from `plural_name`, which is a
  display label — renaming a page heading must not silently move a wire topic.
  It has to be unique across resources, or two resources cross-wire.

  A resource may still write its own `pub_sub` block; AshQuick's publications
  are appended to it and nothing in it is removed. Only the prefix is AshQuick's
  to set, since the subscribe side has no other way to know it.

  To write that block, though, the resource also needs
  `notifiers: [Ash.Notifier.PubSub]` — `notifiers:` is a Spark *extension kind*,
  so it is what makes the `pub_sub` DSL macro available (and runs
  `Ash.Notifier.PubSub`'s own verifiers over what you wrote). AshQuick attaches
  the notifier through `:simple_notifiers` instead, which dispatches identically
  but contributes no DSL — a transformer cannot add an extension, and
  `extensions: [AshQuick]` being the only line a resource needs is the point. A
  resource with a publication of its own therefore declares both:

      use Ash.Resource,
        extensions: [AshQuick],
        notifiers: [Ash.Notifier.PubSub]

      pub_sub do
        # Restated because Spark validates a section's required options when the
        # block is written, before any transformer runs.
        module MyAppWeb.Endpoint

        publish :deactivate, ["deactivated", :id]
      end

  ## Display

  Declares the field a record is labelled by, wherever AshQuick has to name one
  it was not written against — a relationship dropdown option, a details
  header, a print filename:

      ash_quick do
        display do
          label :code
        end
      end

  `label` names an attribute, calculation or aggregate, not an expression: a
  composed label belongs in a calculation. It has to name one of those — a
  relationship holds a struct, not something renderable — or the resource does
  not compile.

  Undeclared, `AshQuick.Display.Transformer` fills it in with the first of
  `:display_name` and `:name` the resource defines, so a resource named by
  either convention needs no `display` block at all. One named by neither does
  not compile: a uuid is the never-crash answer rather than a label, and
  falling back to it would answer "nobody has said what this is called" with
  something that only looks like an answer. Every resource carrying this
  extension therefore has exactly one label field, and
  `AshQuick.Info.display_label/1` reads it back.
  A resource without the extension has no label to read and raises, which is
  why every resource AshQuick names — a QuickView's own, a bare relationship's
  destination, a dropdown's option list — has to carry it.

  `AshQuick.Info.display_label/1` names the field — what a query has to select
  or load — and `display_value/1` reads it off a record.

  ## Lookup

  Names the read action AshQuick runs a search through, and the argument the
  search text arrives as:

      ash_quick do
        lookup do
          action :index           # the default
          search_argument :search # the default
        end
      end

  One declaration stands behind three surfaces. The list page and the export
  both read through it (`AshQuick.LiveView.ListUtils`), and so does every
  BelongsTo and HasMany dropdown pointing *at* this resource
  (`AshQuick.LiveView.Components.BelongsToInput` and `HasManyInput`). They are
  one question — "find me records of this resource matching what the user
  typed" — asked from three places, so a resource answers it once.

  The declaration lives on the resource because the dropdown is the case that
  has nowhere else to put it: a destination is frequently a resource with no
  QuickView of its own, and it still has to say which of its actions a search
  runs through. A QuickView may override the action for its own list with
  `list: [default_action: ...]`, which is the narrower question of what that one
  page lists; the resource's declaration is what every other reader sees.

  Three things are asked of the action, and
  `AshQuick.Lookup.Verifier` holds a declared one to all three. It has to exist;
  it has to accept the `search_argument`, since that is what every caller passes;
  and it has to declare `pagination`, because the list reads it back through
  `Ash.Query.page/2` and the dropdowns read `.results` off the answer — a
  non-paginated action hands back a bare list and raises at the reader rather
  than at the query.

  Nothing is generated for a resource that declares none. An action that merely
  matched the display label would be right for almost nothing — a search is how
  someone finds a record by a barcode, a tracking number or a code, not only by
  its name — and a default that looks like an answer is worse here than a
  compile error with the resource open, for the same reason `display` refuses to
  fall back to `:id`. The verifier is scoped to a declaration the resource
  actually wrote, so a composite-keyed join resource that no dropdown points at
  is never asked for an action it has no use for. Absence is caught instead
  where reachability is known — `AshQuick.LiveView.QuickView.Options` checks the
  same three things over its list action and over every dropdown destination its
  forms can render, while the QuickView compiles.

  `AshQuick.Info.lookup_action/1` and `lookup_search_argument/1` read the
  declaration back.

  ## Activation

  Declares that a record of this resource can be deactivated rather than
  destroyed, and that AshQuick's generic UI should treat it that way:

      ash_quick do
        activation do
          enabled? true
        end
      end

  Declaring it adds an `:active` boolean attribute defaulting to `true`, and
  the `:activate` / `:deactivate` update actions that set it — each only when
  the resource does not define one itself, so a hand-written `:deactivate` with
  its own changes and publications stays as written.

  Four things follow from the declaration. An inactive row is dimmed in the
  list view; it is filtered out of BelongsTo and HasMany dropdowns, so it can
  no longer be chosen for a new record; and `:activate` / `:deactivate` are
  offered as row actions on the list and details pages, whichever of the two
  the record's current state makes meaningful.

  It is off unless declared. AshQuick owns none of this by default because
  `:active` is a column another extension may define for its own reasons —
  filtering a dropdown on a column that means something else silently drops
  rows the actor was entitled to pick. `AshQuick.Info.activation/1` answers
  what was declared and nothing else, and `activation?/1` is the guard every
  one of those four behaviours is behind.

  `:attribute`, `:activate_action` and `:deactivate_action` name the field and
  the two actions when the defaults do not suit.

  ## Versioning

  Guards every write against a concurrent one with an optimistic lock:

      ash_quick do
        versioning do
          enabled? true      # the default
          attribute :version # the counter; defaults to `:version`
        end
      end

  Declared (or left at the default), the resource gains an integer counter
  defaulting to `1`, and every `:update` and `:destroy` is filtered on the
  value the actor loaded and bumps it. A write against a record someone else
  has since changed matches no row and comes back as
  `Ash.Error.Changes.StaleRecord` rather than overwriting them.

  The decision is made in a `before_action` appended last, against the **final**
  changeset — not at the change phase, where Ash's own
  `Ash.Resource.Change.OptimisticLock` decides. Two things follow. A change a
  `before_action` injects is locked, where a change-phase guard would have seen
  an empty changeset and skipped the lock entirely. And an update that ends up a
  genuine no-op neither bumps nor filters, so an orchestration action that does
  not touch its own record cannot collide with a nested update that bumps the
  same record mid-action. Bookkeeping-only changes do not count as changes for
  this purpose — see `AshQuick.Config.versioning_ignored_attributes/1`, which
  reads them off the resource's `bookkeeping` declaration below.

  Reaching that changeset needs the non-atomic path, so every `:update` and
  `:destroy` on a versioned resource is forced to `require_atomic? false`.

  It is **on unless declared otherwise**, the opposite of activation: losing a
  concurrent write is silent and unrecoverable, so a resource that does not want
  the lock has to say so — an append-only log, a row only one writer ever
  touches. Nothing has to be read back to make the lock work — the transformer
  resolves the declaration while the resource compiles and hands the attribute
  to the change. `AshQuick.Info.versioning?/1` and `versioning_attribute/1` are
  there for code outside AshQuick that has to ask.

  A resource that already defines the named attribute keeps its own definition,
  which is why `AshQuick.Versioning.Verifier` refuses to compile one whose
  column is not a lock counter — an extension that gives a resource a
  `:version` meaning the event's schema version is exactly that, and locking on
  it would increment it on every write.

  ## Bookkeeping

  Declares which of the four bookkeeping fields the resource carries — when it
  was created and last written, and by whom:

      ash_quick do
        bookkeeping do
          created_at :created_at   # the default
          updated_at false         # this resource has no last-write time
          created_by :created_by   # the default; a relationship, not a column
          updated_by false
        end
      end

  All four default on, so a resource carrying the full set declares nothing at
  all. The exceptions say so.

  Declaring a field adds it: the two timestamps, the two `belongs_to`
  relationships to the configured `:actor_resource`, and the `relate_actor`
  changes that stamp them — `:created_by` on create, `:updated_by` on every
  write, which is why a create stamps both. The changes are built through
  `relate_actor/1` itself rather than as a literal, so a generated stamp cannot
  drift from a hand-written one.

  **Add-if-absent throughout**, and each of the five pieces is checked
  separately. A resource writing any of them keeps what it wrote, which is what
  the variations here depend on: a resource may keep `public? false` actor
  relationships, stamp only on update, pass `allow_nil?` through to
  `relate_actor` over a column it declares itself, or stamp inside a single
  action rather than globally. None of that is expressible
  in the declaration and none of it needs to be — skipping is the mechanism. A
  resource keeping its own `belongs_to` keeps it whole; the column underneath is
  not separately generated, which is what lets a `define_attribute? false`
  relationship over a hand-written attribute survive.

  The stamping check looks at **every** action's changes, not just the global
  block. Checking only the global one would double-stamp the two resources that
  stamp inside a single action, and silently widen them to every create the
  resource has.

  Generated timestamps carry `always_select?: true`, for the same reason
  `:active` and `:version` do: generic AshQuick code reads them off a record
  whose select list it did not build — a details header, on a page whose
  `fields:` list need never mention a timestamp. The actor columns deliberately
  do **not** get it. A header needs the actor's *label*, which is a relationship
  load rather than the foreign key, and the one policy reading the column does so
  inside a filter expression evaluated as SQL, where nothing has to be selected.

  An actor field is satisfied only by a relationship to the configured
  `:actor_resource`. The name decides nothing on its own — `belongs_to
  :created_by, Seller` is a relationship to a seller, and stamping it would
  write a user's id into a foreign key against another table. A resource with
  one declares `created_by false` and keeps it; that drops its column from the
  ignore list too, which is right, since a change to it is a change to the
  record.

  `AshQuick.Bookkeeping.Verifier` refuses to compile a resource whose
  declaration disagrees with its fields **in either direction** — a field
  declared that is not there, one that is there and declared absent, or an actor
  relationship pointing somewhere other than the actor resource — and refuses a
  declared timestamp that is not `always_select?`. The second
  direction is the one with teeth: a real column left out of the declaration
  drops out of the versioning ignore list below and starts bumping the lock on
  writes that used to be no-ops. The third is what makes `always_select?` a
  guarantee rather than a property of whichever resources happened to be
  generated — without it a hand-written timestamp would quietly lack it and the
  header would work everywhere but there.

  Between them, add-if-absent and the verifier are why this could replace ~35
  resources' hand-written blocks without a single schema change: anything the
  generated form would not reproduce exactly is still written by hand, and the
  verifier will not let the declaration lie about it.

  `:created_at` and `:updated_at` name attributes. `:created_by` and
  `:updated_by` name **relationships** — the ignore list and any actor lookup
  need the destination, and the source attribute is read off the relationship
  rather than assumed to be `<name>_id`, which is what makes a `belongs_to`
  declared `define_attribute? false` resolve correctly.

  The convention is AshQuick's `:created_at`/`:updated_at`, not Ash's default
  `:inserted_at`. Declaring it makes that an owned decision rather than an
  accident of whichever timestamp macro a resource reached for.

  What reads it: `AshQuick.Config.versioning_ignored_attributes/1` and
  `versioning_ignored_relationships/1` are derived per-resource from
  `AshQuick.Info.timestamp_fields/1`, `actor_attributes/1` and `actor_fields/1`,
  rather than from a global list that every resource had to match by convention.

  The boundary is the extension: a resource that does not carry `AshQuick` has
  no declaration and is not checked, so the same four fields remain a convention
  on resources outside it.

  ### What the details page renders

  A QuickView details page carries the declaration under its title, as
  "Created by X on Y · Last updated by Z on W". It is built from
  `AshQuick.Info.bookkeeping/1` and never from the four names, so it renders
  whatever the resource declared and nothing else — the two halves are
  independently absent, and a resource carrying none of the four shows no header
  at all. An append-only resource keeps only the first half; one nobody creates
  through, only the second.

  Each half degrades on its own, so what is missing is a name or a time rather
  than the line. The timestamps need no query work — they are `always_select?`,
  as above. The actor's *label* does: `AshQuick.LiveView.DetailsUtils` loads the
  declared actor relationships with the details record, nested down to
  `AshQuick.Info.display_label/1` of the actor resource. That load runs under
  the actor resource's read policies in the reader's tenant, so a reader who may
  not see the other writer gets "Last updated on Y" with no name. That is the
  designed outcome and not a fallback — the policy is the boundary, and the
  header shows only what its reader could have read anyway.

  The load is deliberately on the details query rather than a preparation on the
  resource's read action. The actor resource carries these fields itself, so a
  preparation would recurse through it, and every unrelated read in the
  application would pay for the joins and the actor's read policies to render a
  header nobody is looking at.

  A QuickView with a custom `action_read` template renders that template instead
  of the generic details view, so it carries whatever header it writes itself.
  The actor relationships are loaded for it either way.

  ## Audit

  Records what every write changed, in the host's own audit store:

      ash_quick do
        audit do
          store MyApp.AuditLog
          exclude_actions [:refresh_availability]
        end
      end

  `AshQuick.Audit.Change` is attached to every create, update and destroy, and
  writes a row per record into the store — `mix igniter.install ash_quick`
  generates one, or `:audit_resource` names an app-wide default that a resource
  only overrides to record somewhere else. The change runs `only_when_valid?`,
  so a write that never happened records nothing, and it skips a batch with no
  actor: an entry names who made the change, and a system write has nobody to
  name.

  **It is on unless a resource turns it off.** Over-auditing is cheap and
  reversible — drop the section, delete the rows — while under-auditing is
  discovered when someone needs the log and it is not there. So a resource that
  should keep no record says so, and says it where a reader can see it:

      audit do
        enabled? false
      end

  Two resources are never audited whatever they declare, because neither can
  record itself: the store, whose writes are the entries, and an embedded
  resource, which has no row of its own for an entry to name.

  There is no fallback for a resource with no store to write to — no logging it
  somewhere else, no dropping the entry — because a sink that "works" without a
  table reintroduces exactly the failure default-on exists to prevent, one
  level down and silently. `AshQuick.Audit.Verifier` refuses to compile a
  resource whose store is missing, names a module that does not exist, is not a
  resource, or cannot take the row. Unchecked, that resource compiles and then
  fails on every write, inside the action's transaction.

  The store is written in `after_batch`, inside the transaction of the action
  that produced the entry, so a record cannot be written without its row and a
  store that refuses the batch fails the write with an
  `AshQuick.Audit.WriteError`. That puts the store on the critical path of
  every write, which is the trade: keep it dumb, with no policies to evaluate
  and no validations to trip.

  A resource wanting only *some* of its actions audited turns the section off
  and attaches the change itself, which keeps the rest of its writes out of
  the log:

      update :do_something do
        change AshQuick.Audit.Change
      end

  A `sensitive?` attribute or argument is replaced with `"**redacted**"` before
  the row is built — in the changeset's attributes, arguments and params, which
  are the only copy of a value the write does not store. A value that should be
  recorded anyway is named per resource:

      audit do
        record_sensitive [:masked_card_number]
      end

  ## Impersonation

  A privileged actor browsing the application as somebody else. There is
  nothing to declare: an impersonation resolves a token back to an actor, so
  the only resource it can name is the configured `:actor_resource`, and that
  is where the `:impersonate` action is generated — on every host, without
  being asked, and on no other resource.

  That action is a manual no-op (`AshQuick.Impersonation.NoOp`): the
  impersonation itself lives in the browser tab that asked for it, so there is
  nothing to write. Running it through Ash anyway is the point — it is what
  enforces the resource's policy over who may stand in for whom, and what
  records the impersonation in the audit log. A resource that writes its own
  `:impersonate` keeps it whole.

  Generating it offers nobody anything. An action nothing authorizes is one
  nobody can run, and a host that wants impersonation still wires the token,
  the register and the page. What the actor resource gains is the place for its
  policy to say who may stand in for whom — including nobody, which is what
  saying nothing says.

  Two things then have to be true of it, and
  `AshQuick.Impersonation.Verifier` refuses to compile it otherwise. It has to
  be audited, because the entry the action leaves is the only record anywhere
  that one person browsed as another — the whole reason impersonation and audit
  ship in one package rather than two. And it has to carry an authorizer, since
  an action whose only job is to be authorized does nothing at all without one,
  and `Ash.can?/3` answering yes for everybody is also what puts it in front of
  them. Write the policy yourself: only the application knows who may
  impersonate whom, and a generated one would AND with it.

  Keeping the action off the list view is worth a line in that policy. Only a
  detail page can finish the job by minting the tab's token, so the list's
  generic row action would leave an audit entry for an impersonation that never
  happened:

      policy action(:impersonate) do
        forbid_if context_equals(:action_source, :ash_quick_list)
        authorize_if MyApp.Checks.ActorIsAdmin
      end

  The mechanism around the action is `AshQuick.Impersonation.Token` (the token),
  `AshQuick.BrowserSessionPresence` (the live register of signed-in tabs, and
  the kill switch for the ones standing in for somebody) and
  `AshQuick.LiveView.BrowserSessionsLive` (the page that reads it).

  ## Field restrictions

  Provides field-level access restrictions. When a field is restricted, two
  things happen:

    1. **UI filtering** — AshQuick forms will hide the field from actors who don't
       pass the check.
    2. **Backend stripping** — A change module strips restricted field values from
       the changeset for unauthorized actors (defense in depth).

  ## Usage

      defmodule MyApp.Settings.User do
        use Ash.Resource,
          extensions: [AshQuick]

        ash_quick do
          field_restrictions do
            restrict :platform_roles, MyApp.FieldRestrictionChecks.ActorHasPlatformRole,
              on: [:create, :update]
          end
        end
      end

  The check accepts any module that implements
  `AshQuick.FieldRestrictions.Check` (i.e. has a `match?/2` callback).
  You can pass a bare module or a `{Module, opts}` tuple when the check needs options.

  ## Options for `restrict`

    * `:field` (required, positional) — The attribute or argument name.
    * `:check` (required, positional) — A check module or `{CheckModule, opts}` tuple.
      The module must implement `AshQuick.FieldRestrictions.Check`.
    * `:on` (optional) — A list of action names this restriction applies to.
      When omitted, the restriction applies to **all** create/update actions that
      accept or include the field.
    * `:description` (optional) — A human-readable description for documentation.
  """

  @restriction %Spark.Dsl.Entity{
    name: :restrict,
    describe: "Restricts a field based on a field restriction check.",
    target: AshQuick.FieldRestrictions.FieldRestriction,
    args: [:field, :check],
    identifier: :field,
    schema: [
      field: [
        type: :atom,
        required: true,
        doc: "The attribute or argument name to restrict."
      ],
      check: [
        type: {:spark_behaviour, AshQuick.FieldRestrictions.Check},
        required: true,
        doc:
          "A check module or `{CheckModule, opts}` tuple. The module must implement `AshQuick.FieldRestrictions.Check`."
      ],
      on: [
        type: {:wrap_list, :atom},
        doc:
          "Action names this restriction applies to. When omitted, applies to all create/update actions."
      ],
      description: [
        type: :string,
        doc: "A human-readable description of the restriction."
      ]
    ]
  }

  @field_restrictions %Spark.Dsl.Section{
    name: :field_restrictions,
    describe: "Declare field-level access restrictions for action inputs.",
    entities: [@restriction]
  }

  @liveness %Spark.Dsl.Section{
    name: :liveness,
    describe: "Declare how this resource's changes reach AshQuick's LiveViews.",
    schema: [
      enabled?: [
        type: :boolean,
        default: true,
        doc: "Whether changes to this resource are published at all."
      ],
      prefix: [
        type: :string,
        doc:
          "The PubSub topic for this resource. Defaults to the resource's `short_name`. Must be unique across resources."
      ]
    ]
  }

  @display %Spark.Dsl.Section{
    name: :display,
    describe: "Declare how a record of this resource is labelled in generic UI.",
    schema: [
      label: [
        type: :atom,
        doc:
          "The attribute, calculation or aggregate a record is labelled by — naming anything else does not compile. Filled in at compile time with `:display_name`, then `:name`, when not declared; a resource matching neither convention has to declare one."
      ]
    ]
  }

  @activation %Spark.Dsl.Section{
    name: :activation,
    describe: "Declare that a record of this resource is deactivated rather than destroyed.",
    schema: [
      enabled?: [
        type: :boolean,
        default: false,
        doc:
          "Whether this resource carries activation at all. Off when the section is absent, since `:active` is a column another extension may own for unrelated reasons."
      ],
      attribute: [
        type: :atom,
        default: :active,
        doc:
          "The boolean attribute holding the state. Added when the resource does not define it."
      ],
      activate_action: [
        type: :atom,
        default: :activate,
        doc:
          "The update action setting the attribute true. Added when the resource does not define it."
      ],
      deactivate_action: [
        type: :atom,
        default: :deactivate,
        doc:
          "The update action setting the attribute false. Added when the resource does not define it."
      ]
    ]
  }

  @versioning %Spark.Dsl.Section{
    name: :versioning,
    describe: "Declare that writes to this resource are guarded by an optimistic lock.",
    schema: [
      enabled?: [
        type: :boolean,
        default: AshQuick.Versioning.Declaration.default_enabled?(),
        doc:
          "Whether this resource carries an optimistic lock. On unless declared otherwise — a resource that cannot lose a concurrent write has to say so."
      ],
      attribute: [
        type: :atom,
        default: AshQuick.Versioning.Declaration.default_attribute(),
        doc:
          "The integer attribute holding the counter. Added when the resource does not define it; a resource defining it as anything but a lock counter does not compile."
      ],
      reason: [
        type: :string,
        doc:
          "Why this resource can afford to lose a concurrent write. Nothing reads it at runtime; `mix ash_quick.check` reports an `enabled? false` that states none."
      ]
    ]
  }

  @bookkeeping %Spark.Dsl.Section{
    name: :bookkeeping,
    describe: "Declare which bookkeeping fields this resource carries.",
    schema: [
      created_at: [
        type: :atom,
        default: AshQuick.Bookkeeping.Declaration.default(:created_at),
        doc:
          "The attribute holding the creation time, or `false` when the resource has none. Added when the resource does not define it."
      ],
      updated_at: [
        type: :atom,
        default: AshQuick.Bookkeeping.Declaration.default(:updated_at),
        doc:
          "The attribute holding the last-write time, or `false` when the resource has none. Added when the resource does not define it."
      ],
      created_by: [
        type: :atom,
        default: AshQuick.Bookkeeping.Declaration.default(:created_by),
        doc:
          "The relationship to the actor that created the record, or `false` when the resource stamps none. Added, pointed at the configured `:actor_resource`, when the resource does not define it; a relationship of that name pointing anywhere else does not compile."
      ],
      updated_by: [
        type: :atom,
        default: AshQuick.Bookkeeping.Declaration.default(:updated_by),
        doc:
          "The relationship to the actor that last wrote the record, or `false` when the resource stamps none. Added, pointed at the configured `:actor_resource`, when the resource does not define it; a relationship of that name pointing anywhere else does not compile."
      ]
    ]
  }

  @audit %Spark.Dsl.Section{
    name: :audit,
    describe: "Declare that every write to this resource is recorded in an audit log.",
    schema: [
      enabled?: [
        type: :boolean,
        default: AshQuick.Audit.Declaration.default_enabled?(),
        doc:
          "Whether every create, update and destroy of this resource is recorded in its audit store. On unless the resource turns it off."
      ],
      store: [
        type: {:spark, Ash.Resource},
        doc:
          "The resource entries for this resource are written to. Defaults to the app-wide `:audit_resource`; a resource with neither refuses to compile."
      ],
      exclude_actions: [
        type: {:list, :atom},
        default: AshQuick.Audit.Declaration.default_exclude_actions(),
        doc:
          "Actions that record nothing — an action that authorizes and emits but writes nothing, where a row per record would say a change happened that did not."
      ],
      record_sensitive: [
        type: {:list, :atom},
        default: AshQuick.Audit.Declaration.default_record_sensitive(),
        doc:
          "Attributes and arguments recorded in full despite carrying `sensitive?`. Every other sensitive value is replaced with `\"**redacted**\"` before any logger sees it."
      ],
      reason: [
        type: :string,
        doc:
          "Why no record of who changed this resource is needed. Nothing reads it at runtime; `mix ash_quick.check` reports an `enabled? false` that states none."
      ]
    ]
  }

  @lookup %Spark.Dsl.Section{
    name: :lookup,
    describe:
      "Declare the searchable read action AshQuick drives this resource's list, export and relationship dropdowns from.",
    schema: [
      action: [
        type: :atom,
        default: AshQuick.Lookup.Declaration.default_action(),
        doc:
          "The read action a search runs through. Must accept the `search_argument` and paginate under a `default_limit`; a declared action failing either does not compile."
      ],
      search_argument: [
        type: :atom,
        default: AshQuick.Lookup.Declaration.default_search_argument(),
        doc:
          "The argument the user's search text is passed as. `nil` is what the action receives when there is nothing to search for."
      ]
    ]
  }

  @ash_quick %Spark.Dsl.Section{
    name: :ash_quick,
    describe: "AshQuick configuration for this resource.",
    sections: [
      @liveness,
      @display,
      @lookup,
      @activation,
      @versioning,
      @bookkeeping,
      @audit,
      @field_restrictions
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@ash_quick],
    transformers: [
      AshQuick.Audit.Transformer,
      AshQuick.Impersonation.Transformer,
      AshQuick.Activation.Transformer,
      AshQuick.Bookkeeping.Transformer,
      AshQuick.Versioning.Transformer,
      AshQuick.Display.Transformer,
      AshQuick.FieldRestrictions.Transformer,
      AshQuick.PubSub.Transformer
    ],
    verifiers: [
      AshQuick.Identity.Verifier,
      AshQuick.Versioning.Verifier,
      AshQuick.Bookkeeping.Verifier,
      AshQuick.Audit.Verifier,
      AshQuick.Impersonation.Verifier,
      AshQuick.Lookup.Verifier
    ]

  @surface_sources [:ash_quick_details, :ash_quick_list, :ash_quick_list_bulk]
  @form_source :ash_quick_form

  @doc """
  The `action_source` values AshQuick stamps for a *visibility surface* — one
  per place a control can be probed and shown: `:ash_quick_details`,
  `:ash_quick_list`, `:ash_quick_list_bulk`. A policy scoped to these hides a
  control on that surface.
  """
  def surface_sources, do: @surface_sources

  @doc """
  The `action_source` stamped on a QuickView create/update form submit.

  Deliberately **not** one of `surface_sources/0`: a form submit records its
  provenance in the audit log, but must not count as a visibility surface. A
  policy scoped to `surface_sources/0` therefore never fires at submit, so a
  stale or forged submit routes to the action's own validation (a 409/422),
  not a `Forbidden` — the button-hiding happened at the row-action probe.
  """
  def form_source, do: @form_source

  @doc """
  `Ash.can?/3` stamped with a QuickView surface's `action_source`.

  `source` is one of `surface_sources/0`. QuickView probes controls through
  this so a resource may scope a policy to a single surface — hiding a
  control there (e.g. a state-illegal action in the details view) without
  that policy also firing on non-QuickView callers such as the JSON API,
  where the same precondition should surface as a validation, not a
  `Forbidden`. Custom QuickView templates should call this instead of a
  bare `Ash.can?/2` so their controls participate in surface-scoped policies.

  An action the resource does not define answers `false`. Surfaces probe for
  actions they merely hope are there — the list view asks about `:create`
  before offering its button — and an append-only resource that defines no
  such action is answering the question, not hitting an error.
  """
  def can?(target, scope, source, opts \\ []) when source in @surface_sources do
    opts =
      opts
      |> Keyword.put_new(:log_policy_breakdown?, false)
      |> Keyword.update(:context, %{action_source: source}, &Map.put(&1, :action_source, source))

    defined?(target) and Ash.can?(target, scope, opts)
  end

  defp defined?({resource, action}) when is_atom(resource) and is_atom(action) do
    not is_nil(Ash.Resource.Info.action(resource, action))
  end

  defp defined?(_target), do: true
end
