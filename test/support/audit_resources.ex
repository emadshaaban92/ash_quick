defmodule AshQuick.Test.AuditDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshQuick.Test.Credential do
  @moduledoc """
  Stands in for an audited resource holding a secret.

  Exercises the redaction `AshQuick.Audit.Change` performs before the row is
  built — a `sensitive?` attribute and a `sensitive?` argument, one of each
  named in `record_sensitive` so both sides of that decision are driven. It is
  in-memory because the assertions are about the audit row rather than about
  where the audited resource keeps itself.
  """
  use Ash.Resource,
    domain: AshQuick.Test.AuditDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :api_key, :string, public?: true, sensitive?: true
    # Sensitive, and named in `record_sensitive` below: it is masked at rest,
    # and which card was used is the whole point of the entry.
    attribute :masked_card_number, :string, public?: true, sensitive?: true
  end

  actions do
    default_accept [:name, :api_key, :masked_card_number]
    defaults [:read, :create, :update, :destroy]

    update :rotate do
      require_atomic? false

      argument :password, :string, sensitive?: true
      argument :reason, :string

      change fn changeset, _context ->
        Ash.Changeset.change_attribute(
          changeset,
          :api_key,
          Ash.Changeset.get_argument(changeset, :password)
        )
      end
    end

    # Excluded below, so the tests have an action that records nothing whoever
    # runs it.
    update :touch
  end

  ash_quick do
    audit do
      record_sensitive [:masked_card_number]
      exclude_actions [:touch]
      # Context keys a host chose to keep: the queue a job ran from, and the
      # support ticket a write was made under.
      record_context [:queue, :ticket]
    end

    display do
      label :name
    end

    liveness do
      enabled? false
    end

    versioning do
      enabled? false
    end

    bookkeeping do
      inserted_at false
      updated_at false
      inserted_by false
      updated_by false
    end
  end
end

defmodule AshQuick.Test.Tally do
  @moduledoc """
  An audited resource whose updates and destroys run atomically.

  Nothing here says `require_atomic? false`, and versioning is off, so nothing
  turns it off either: `AshQuick.Audit.Change` runs on Ash's atomic path. There
  an accepted input arrives in `changeset.atomics` rather than in
  `changeset.attributes`, and an `atomic_update` is an expression only the data
  layer evaluates — which is what the entry has to be built from.
  """
  use Ash.Resource,
    domain: AshQuick.Test.AuditDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :count, :integer, public?: true, allow_nil?: false, default: 0
    attribute :pin, :string, public?: true, sensitive?: true
  end

  actions do
    default_accept [:name, :pin]
    defaults [:read, :create]

    update :rename, accept: [:name, :pin]

    update :bump do
      accept []
      change atomic_update(:count, expr(count + 1))
    end

    # A secret worked out by the data layer rather than given: an expression on
    # a sensitive attribute, which is neither input nor something to print.
    update :scramble do
      accept []
      change atomic_update(:pin, expr(name <> "-0000"))
    end

    # The value the caller passed lands in the expression as a literal.
    update :bump_by do
      accept []
      argument :by, :integer, allow_nil?: false
      change atomic_update(:count, expr(count + ^arg(:by)))
    end

    # The same with a sensitive argument, which Ash puts in as a literal too —
    # and on a bulk update folds `1 + ^arg(:bonus)` into a single one.
    update :bump_secretly do
      accept []
      argument :bonus, :integer, allow_nil?: false, sensitive?: true
      change atomic_update(:count, expr(count + (1 + ^arg(:bonus))))
    end

    # A required attribute set by an expression that can come to nil, which Ash
    # wraps in a required check before the data layer sees it.
    update :measure do
      accept []
      change atomic_update(:count, expr(string_length(name)))
    end

    # A string set by an expression, which `Ash.Type.String` wraps in a trim and
    # a check for an empty result.
    update :exclaim do
      accept []
      change atomic_update(:name, expr(name <> "!"))
    end

    # Grouping Ash prints no parentheses for.
    update :double_up do
      accept []
      change atomic_update(:count, expr((count + 1) * 2))
    end

    # A secret carried into another attribute's expression by `^atomic_ref/1`.
    update :sign do
      accept [:pin]
      change atomic_update(:name, expr(name <> "/" <> ^atomic_ref(:pin)))
    end

    # The same expression on the in-memory path: the anonymous change has no
    # `atomic/3`, so the update cannot run atomically, and the expression still
    # reaches the data layer through `changeset.atomics`.
    update :bump_in_memory do
      accept []
      require_atomic? false

      change atomic_update(:count, expr(count + 1))
      change fn changeset, _context -> changeset end
    end

    destroy :remove
  end

  ash_quick do
    display do
      label :name
    end

    liveness do
      enabled? false
    end

    versioning do
      enabled? false
    end

    bookkeeping do
      inserted_at false
      updated_at false
      inserted_by false
      updated_by false
    end
  end
end

defmodule AshQuick.Test.VersionedTally do
  @moduledoc """
  `AshQuick.Test.Tally` with versioning on. Its updates still run atomically,
  and there the lock sets the counter by an expression of its own —
  `if <anything written changed> do version + 1 else version end` — which
  repeats every expression the write set, a sensitive one included.
  """
  use Ash.Resource,
    domain: AshQuick.Test.AuditDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :count, :integer, public?: true, allow_nil?: false, default: 0
    attribute :pin, :string, public?: true, sensitive?: true
  end

  actions do
    defaults [:read, create: [:name, :pin]]

    update :bump do
      accept []
      change atomic_update(:count, expr(count + 1))
    end

    update :scramble do
      accept []
      change atomic_update(:pin, expr(name <> "-0000"))
    end
  end

  ash_quick do
    display do
      label :name
    end

    liveness do
      enabled? false
    end

    bookkeeping do
      inserted_at false
      updated_at false
      inserted_by false
      updated_by false
    end
  end
end

defmodule AshQuick.Test.StampedTally do
  @moduledoc """
  `AshQuick.Test.Tally` with an update timestamp. On Ash's atomic path an update
  default arrives as an expression too — `if <changed> do now() else
  touched_at end` — which the in-memory path records as a value.
  """
  use Ash.Resource,
    domain: AshQuick.Test.AuditDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :count, :integer, public?: true, allow_nil?: false, default: 0
    update_timestamp :touched_at, public?: true
  end

  actions do
    defaults [:read, create: [:name]]

    update :bump do
      accept []
      change atomic_update(:count, expr(count + 1))
    end
  end

  ash_quick do
    display do
      label :name
    end

    liveness do
      enabled? false
    end

    versioning do
      enabled? false
    end

    bookkeeping do
      inserted_at false
      updated_at false
      inserted_by false
      updated_by false
    end
  end
end

defmodule AshQuick.Test.RefusingStore do
  @moduledoc """
  An audit store that cannot take the row.

  A store is written inside the transaction of the write it records, so one
  that refuses the batch fails that write — the guarantee that a record cannot
  exist without an entry saying who made it. What refuses in production is a
  column that is gone, a foreign key to a deleted actor, or the database being
  down; a validation stands in for all of those, because what the store said is
  what has to reach the caller either way.

  It carries every column `AshQuick.Audit.Row` fills, so the refusal is the
  store's own and not `AshQuick.Audit.Verifier` catching a store that had
  drifted.
  """
  use Ash.Resource,
    domain: AshQuick.Test.AuditDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :resource_name, :atom, public?: true
    attribute :resource_id, :uuid, public?: true
    attribute :action_type, :atom, public?: true
    attribute :action_name, :atom, public?: true
    attribute :attributes, :map, public?: true
    attribute :arguments, :map, public?: true
    attribute :context, :map, public?: true
    attribute :actor_id, :uuid, public?: true
    attribute :real_actor_id, :uuid, public?: true
    attribute :ip, :string, public?: true
    attribute :tenant, :uuid, public?: true
  end

  actions do
    default_accept :*
    defaults [:read]

    create :create do
      validate fn _changeset, _context ->
        {:error, field: :attributes, message: "audit store unreachable"}
      end
    end
  end

  ash_quick do
    audit do
      # Configured as the store only while a test swaps it in, so the library
      # cannot tell it is one — it says so itself.
      enabled? false
    end

    display do
      # An entry is "what was done to what"; the store never reaches a page, but
      # every AshQuick resource has to answer what it is called.
      label :resource_name
    end

    liveness do
      enabled? false
    end

    versioning do
      enabled? false
    end

    bookkeeping do
      inserted_at false
      updated_at false
      inserted_by false
      updated_by false
    end
  end
end

defmodule AshQuick.Test.PartialAuditStore do
  @moduledoc """
  A store that has drifted from what AshQuick writes: everything but the two
  columns the provenance contract added.

  Carries no AshQuick extension of its own, because a store does not need one —
  it is a table. What `AshQuick.AuditVerifierTest` reads off it is the report
  `AshQuick.Audit.Verifier` gives for a store one migration behind.
  """
  use Ash.Resource, domain: AshQuick.Test.AuditDomain, data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :resource_name, :atom
    attribute :resource_id, :uuid
    attribute :action_type, :atom
    attribute :action_name, :atom
    attribute :attributes, :map
    attribute :arguments, :map
    attribute :context, :map
    attribute :actor_id, :uuid
    attribute :real_actor_id, :uuid
  end

  actions do
    default_accept :*
    defaults [:create, :read]
  end
end

defmodule AshQuick.Test.PrivateAuditStore do
  @moduledoc """
  Every column AshQuick fills, two of them private — so `default_accept :*`
  leaves them out and the row is refused on the way in rather than by the table.
  """
  use Ash.Resource, domain: AshQuick.Test.AuditDomain, data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :resource_name, :atom, public?: true
    attribute :resource_id, :uuid, public?: true
    attribute :action_type, :atom, public?: true
    attribute :action_name, :atom, public?: true
    attribute :attributes, :map, public?: true
    attribute :arguments, :map, public?: true
    attribute :context, :map
    attribute :actor_id, :uuid, public?: true
    attribute :real_actor_id, :uuid, public?: true
    attribute :ip, :string
    attribute :tenant, :uuid, public?: true
  end

  actions do
    default_accept :*
    defaults [:create, :read]
  end
end

defmodule AshQuick.Test.ReadOnlyAuditStore do
  @moduledoc """
  Every column AshQuick fills and nowhere to put them: a store with no `:create`
  action takes no row at all, rather than being one column short of taking it.
  """
  use Ash.Resource, domain: AshQuick.Test.AuditDomain, data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :resource_name, :atom, public?: true
    attribute :resource_id, :uuid, public?: true
    attribute :action_type, :atom, public?: true
    attribute :action_name, :atom, public?: true
    attribute :attributes, :map, public?: true
    attribute :arguments, :map, public?: true
    attribute :context, :map, public?: true
    attribute :actor_id, :uuid, public?: true
    attribute :real_actor_id, :uuid, public?: true
    attribute :ip, :string, public?: true
    attribute :tenant, :uuid, public?: true
  end

  actions do
    default_accept :*
    defaults [:read]
  end
end

defmodule AshQuick.Test.ArgumentAuditStore do
  @moduledoc """
  Takes the two actor columns through arguments rather than through `accept`,
  which is how a store relating its actor takes them. The row lands either way,
  so `AshQuick.Audit.Verifier` must not refuse this.
  """
  use Ash.Resource, domain: AshQuick.Test.AuditDomain, data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :resource_name, :atom, public?: true
    attribute :resource_id, :uuid, public?: true
    attribute :action_type, :atom, public?: true
    attribute :action_name, :atom, public?: true
    attribute :attributes, :map, public?: true
    attribute :arguments, :map, public?: true
    attribute :context, :map, public?: true
    attribute :actor_id, :uuid, public?: true
    attribute :real_actor_id, :uuid, public?: true
    attribute :ip, :string, public?: true
    attribute :tenant, :uuid, public?: true
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :resource_name,
        :resource_id,
        :action_type,
        :action_name,
        :attributes,
        :arguments,
        :context,
        :ip,
        :tenant
      ]

      argument :actor_id, :uuid
      argument :real_actor_id, :uuid
    end
  end
end

defmodule AshQuick.Test.LegacyAuditStore do
  @moduledoc """
  A store one migration behind: every required column and no `changes`.

  `changes` is optional, so this has to keep taking rows — `Ash.bulk_create`
  refuses an input the action does not have, so the key must be absent from the
  row rather than nil. `AshQuick.Test.LegacyCredential` names it, which is what
  keeps the assertion off the suite-wide `:audit_resource` and the test async.
  """
  use Ash.Resource, domain: AshQuick.Test.AuditDomain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :resource_name, :atom, public?: true
    attribute :resource_id, :uuid, public?: true
    attribute :action_type, :atom, public?: true
    attribute :action_name, :atom, public?: true
    attribute :attributes, :map, public?: true
    attribute :arguments, :map, public?: true
    attribute :context, :map, public?: true
    attribute :actor_id, :uuid, public?: true
    attribute :real_actor_id, :uuid, public?: true
    attribute :ip, :string, public?: true
    attribute :tenant, :uuid, public?: true
  end

  actions do
    default_accept :*
    defaults [:create, :read]
  end
end

defmodule AshQuick.Test.LegacyCredential do
  @moduledoc """
  An audited resource recording into a store that predates `changes`.

  Nothing about it says so — the resource is written exactly as one on a
  current store would be. Whether the column is there is the store's question,
  and the row is built either way.
  """
  use Ash.Resource,
    domain: AshQuick.Test.AuditDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  actions do
    default_accept [:name]
    defaults [:read, :create, :update]
  end

  ash_quick do
    audit do
      store AshQuick.Test.LegacyAuditStore
    end

    display do
      label :name
    end

    liveness do
      enabled? false
    end

    versioning do
      enabled? false
    end

    bookkeeping do
      inserted_at false
      updated_at false
      inserted_by false
      updated_by false
    end
  end
end

defmodule AshQuick.Test.TextKeyAuditStore do
  @moduledoc """
  A store whose `resource_id` is text, as the installer generates it, so one
  store takes a row for any primary key. `AshQuick.Test.NumberedCredential`
  records into it with an integer key.
  """
  use Ash.Resource, domain: AshQuick.Test.AuditDomain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :resource_name, :atom, public?: true
    attribute :resource_id, :string, public?: true
    attribute :action_type, :atom, public?: true
    attribute :action_name, :atom, public?: true
    attribute :attributes, :map, public?: true
    attribute :arguments, :map, public?: true
    attribute :context, :map, public?: true
    attribute :actor_id, :uuid, public?: true
    attribute :real_actor_id, :uuid, public?: true
    attribute :ip, :string, public?: true
    attribute :tenant, :uuid, public?: true
  end

  actions do
    default_accept :*
    defaults [:create, :read]
  end
end

defmodule AshQuick.Test.NumberedCredential do
  @moduledoc """
  An audited resource keyed by an integer, recording into
  `AshQuick.Test.TextKeyAuditStore`.
  """
  use Ash.Resource,
    domain: AshQuick.Test.AuditDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
  end

  actions do
    default_accept [:id, :name]
    defaults [:read, :create, :update]
  end

  ash_quick do
    audit do
      store AshQuick.Test.TextKeyAuditStore
    end

    display do
      label :name
    end

    liveness do
      enabled? false
    end

    versioning do
      enabled? false
    end

    bookkeeping do
      inserted_at false
      updated_at false
      inserted_by false
      updated_by false
    end
  end
end

defmodule AshQuick.Test.MistypedChangesStore do
  @moduledoc """
  A store whose `changes` column is a string. Every write would refuse it, so
  `AshQuick.Audit.Verifier` says so while the audited resource compiles.
  """
  use Ash.Resource, domain: AshQuick.Test.AuditDomain, data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :resource_name, :atom, public?: true
    attribute :resource_id, :uuid, public?: true
    attribute :action_type, :atom, public?: true
    attribute :action_name, :atom, public?: true
    attribute :attributes, :map, public?: true
    attribute :arguments, :map, public?: true
    attribute :context, :map, public?: true
    attribute :changes, :string, public?: true
    attribute :actor_id, :uuid, public?: true
    attribute :real_actor_id, :uuid, public?: true
    attribute :ip, :string, public?: true
    attribute :tenant, :uuid, public?: true
  end

  actions do
    default_accept :*
    defaults [:create, :read]
  end
end

defmodule AshQuick.Test.UnacceptedChangesStore do
  @moduledoc """
  A `changes` column of the right type that the `:create` action will not take —
  private, so `accept :*` skips it. The same `NoSuchInput` one write later.
  """
  use Ash.Resource, domain: AshQuick.Test.AuditDomain, data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :resource_name, :atom, public?: true
    attribute :resource_id, :uuid, public?: true
    attribute :action_type, :atom, public?: true
    attribute :action_name, :atom, public?: true
    attribute :attributes, :map, public?: true
    attribute :arguments, :map, public?: true
    attribute :context, :map, public?: true
    attribute :changes, :map
    attribute :actor_id, :uuid, public?: true
    attribute :real_actor_id, :uuid, public?: true
    attribute :ip, :string, public?: true
    attribute :tenant, :uuid, public?: true
  end

  actions do
    default_accept :*
    defaults [:create, :read]
  end
end

defmodule AshQuick.Test.RequiredActorAuditStore do
  @moduledoc """
  Every column AshQuick fills, with an `actor_id` that refuses `nil` — a store
  written when a write with no actor recorded nothing. Every such write is now
  recorded with `actor_id: nil`, so this one would fail each of them.
  """
  use Ash.Resource, domain: AshQuick.Test.AuditDomain, data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :resource_name, :atom, public?: true
    attribute :resource_id, :uuid, public?: true
    attribute :action_type, :atom, public?: true
    attribute :action_name, :atom, public?: true
    attribute :attributes, :map, public?: true
    attribute :arguments, :map, public?: true
    attribute :context, :map, public?: true
    attribute :actor_id, :uuid, allow_nil?: false, public?: true
    attribute :real_actor_id, :uuid, public?: true
    attribute :ip, :string, public?: true
    attribute :tenant, :uuid, public?: true
  end

  actions do
    default_accept :*
    defaults [:create, :read]
  end
end

defmodule AshQuick.Test.RequiredActorRelationshipAuditStore do
  @moduledoc """
  The same refusal, made through a `belongs_to :actor` rather than a plain
  attribute — which is where the generated store declares it. The real actor is
  related too, as there, and takes `nil`, so the refusal is the actor's alone.
  """
  use Ash.Resource, domain: AshQuick.Test.AuditDomain, data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :resource_name, :atom, public?: true
    attribute :resource_id, :uuid, public?: true
    attribute :action_type, :atom, public?: true
    attribute :action_name, :atom, public?: true
    attribute :attributes, :map, public?: true
    attribute :arguments, :map, public?: true
    attribute :context, :map, public?: true
    attribute :ip, :string, public?: true
    attribute :tenant, :uuid, public?: true
  end

  relationships do
    belongs_to :actor, AshQuick.Test.Actor do
      public? true
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :real_actor, AshQuick.Test.Actor do
      public? true
      allow_nil? true
      attribute_writable? true
    end
  end

  actions do
    default_accept :*
    defaults [:create, :read]
  end
end

defmodule AshQuick.Test.RequiredActorArgumentAuditStore do
  @moduledoc """
  A nullable `actor_id` column the `:create` action takes through an argument
  that refuses `nil` — the refusal moved from the table to the way in.
  """
  use Ash.Resource, domain: AshQuick.Test.AuditDomain, data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :resource_name, :atom, public?: true
    attribute :resource_id, :uuid, public?: true
    attribute :action_type, :atom, public?: true
    attribute :action_name, :atom, public?: true
    attribute :attributes, :map, public?: true
    attribute :arguments, :map, public?: true
    attribute :context, :map, public?: true
    attribute :actor_id, :uuid, public?: true
    attribute :real_actor_id, :uuid, public?: true
    attribute :ip, :string, public?: true
    attribute :tenant, :uuid, public?: true
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :resource_name,
        :resource_id,
        :action_type,
        :action_name,
        :attributes,
        :arguments,
        :context,
        :real_actor_id,
        :ip,
        :tenant
      ]

      argument :actor_id, :uuid, allow_nil?: false
    end
  end
end

defmodule AshQuick.Test.RequiredRealActorAuditStore do
  @moduledoc """
  A nullable `actor_id` beside a `real_actor_id` that refuses `nil` — a store
  written when the real actor was never `nil` while there was an actor, and
  there was no row without one.
  """
  use Ash.Resource, domain: AshQuick.Test.AuditDomain, data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :resource_name, :atom, public?: true
    attribute :resource_id, :uuid, public?: true
    attribute :action_type, :atom, public?: true
    attribute :action_name, :atom, public?: true
    attribute :attributes, :map, public?: true
    attribute :arguments, :map, public?: true
    attribute :context, :map, public?: true
    attribute :actor_id, :uuid, public?: true
    attribute :real_actor_id, :uuid, allow_nil?: false, public?: true
    attribute :ip, :string, public?: true
    attribute :tenant, :uuid, public?: true
  end

  actions do
    default_accept :*
    defaults [:create, :read]
  end
end

defmodule AshQuick.Test.Dossier do
  @moduledoc """
  A confidential record whose opening is recorded.

  `:open` and `:browse` are listed in `read_actions`, so every record they
  return gets an audit row, which keeps the `:ticket` it was opened under;
  `:read`, the primary action, is not, and stands for the lists and searches
  that must record nothing. `:open` takes a `sensitive?` argument and one named
  in `record_sensitive`, so a read's arguments are redacted on the same rule as
  a write's.

  Its read policy lets an actor see only their own dossiers, so a read the
  policies filter to nothing is a read that returns nothing.
  """
  use Ash.Resource,
    domain: AshQuick.Test.AuditDomain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
    attribute :owner_id, :uuid, public?: true
    attribute :folder_id, :uuid, public?: true
    attribute :hidden?, :boolean, public?: true, default: false, allow_nil?: false
  end

  # A host's own hook that drops records after the data layer returned them,
  # as a resource-wide preparation: the read does not return a hidden dossier,
  # so it must not be recorded as read either.
  preparations do
    prepare fn query, _context ->
      Ash.Query.after_action(query, fn _query, records ->
        {:ok, Enum.reject(records, &(&1.hidden? == true))}
      end)
    end
  end

  calculations do
    calculate :heading, :string, expr(title <> "!"), public?: true
  end

  relationships do
    belongs_to :folder, AshQuick.Test.DossierFolder do
      define_attribute? false
      public? true
    end
  end

  actions do
    default_accept [:title, :owner_id, :folder_id, :hidden?]
    defaults [:read, :create]

    read :open do
      get? true

      argument :code, :string, sensitive?: true
      argument :badge, :string, sensitive?: true
      argument :purpose, :string
    end

    read :browse do
      pagination offset?: true, keyset?: true, required?: false
    end
  end

  code_interface do
    define :open, get_by: [:id]
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(owner_id == ^actor(:id))
    end

    policy action_type(:create) do
      authorize_if always()
    end
  end

  ash_quick do
    audit do
      read_actions [:open, :browse]
      record_sensitive [:badge]
      record_context [:ticket]
    end

    display do
      label :title
    end

    liveness do
      enabled? false
    end

    versioning do
      enabled? false
    end

    bookkeeping do
      inserted_at false
      updated_at false
      inserted_by false
      updated_by false
    end
  end
end

defmodule AshQuick.Test.DossierFolder do
  @moduledoc """
  Holds dossiers, and loads them through `AshQuick.Test.Dossier`'s listed
  `:browse` — so loading the relationship is a read of each dossier it returns.
  Its own reads are not listed, and record nothing.
  """
  use Ash.Resource,
    domain: AshQuick.Test.AuditDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  relationships do
    has_many :dossiers, AshQuick.Test.Dossier do
      destination_attribute :folder_id
      read_action :browse
      public? true
    end
  end

  actions do
    default_accept [:name]
    defaults [:read, :create]
  end

  ash_quick do
    display do
      label :name
    end

    liveness do
      enabled? false
    end

    versioning do
      enabled? false
    end

    bookkeeping do
      inserted_at false
      updated_at false
      inserted_by false
      updated_by false
    end
  end
end

defmodule AshQuick.Test.RefusedDossier do
  @moduledoc """
  An opened record whose store refuses every row: `AshQuick.Test.RefusingStore`.
  Its create is excluded, so a record can exist for the read to fail on.
  """
  use Ash.Resource,
    domain: AshQuick.Test.AuditDomain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
  end

  actions do
    default_accept [:title]
    defaults [:read, :create]

    read :open do
      get? true
    end
  end

  ash_quick do
    audit do
      store AshQuick.Test.RefusingStore
      exclude_actions [:create]
      read_actions [:open]
    end

    display do
      label :title
    end

    liveness do
      enabled? false
    end

    versioning do
      enabled? false
    end

    bookkeeping do
      inserted_at false
      updated_at false
      inserted_by false
      updated_by false
    end
  end
end

defmodule AshQuick.Test.JsonAuditStore do
  @moduledoc """
  An audit store that holds its rows as JSON, as a host's `jsonb` columns do.

  ETS keeps any term, so `AshQuick.Test.AuditLog` takes a row that no database
  column could. This store refuses one the way a `jsonb` column does — a value
  `Jason` cannot encode, such as bytes that are not valid UTF-8, fails the
  insert — so a row only reaches it if a real store would have taken it.
  """
  use Ash.Resource, domain: AshQuick.Test.AuditDomain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :resource_name, :atom, public?: true
    attribute :resource_id, :uuid, public?: true
    attribute :action_type, :atom, public?: true
    attribute :action_name, :atom, public?: true
    attribute :attributes, :map, public?: true
    attribute :arguments, :map, public?: true
    attribute :context, :map, public?: true
    attribute :changes, :map, public?: true
    attribute :actor_id, :uuid, public?: true
    attribute :real_actor_id, :uuid, public?: true
    attribute :ip, :string, public?: true
    attribute :tenant, :uuid, public?: true
  end

  actions do
    default_accept :*
    defaults [:read]

    create :create do
      validate fn changeset, _context ->
        Enum.reduce_while([:attributes, :arguments, :context, :changes], :ok, fn field, :ok ->
          case Jason.encode(Ash.Changeset.get_attribute(changeset, field)) do
            {:ok, _json} -> {:cont, :ok}
            {:error, error} -> {:halt, {:error, field: field, message: Exception.message(error)}}
          end
        end)
      end
    end
  end
end

defmodule AshQuick.Test.Report do
  @moduledoc """
  A record a file is made from, with auditing, bookkeeping stamps and
  versioning all on.

  `:export` is a download that only records that it happened: it accepts
  nothing and writes no attribute. Its `before_transaction` hook makes the file
  and carries it to the `after_action` hook through the changeset context,
  under a key the resource does not list in `record_context`, and sets the
  `:filename` argument; the `after_action` hook marks the record with
  `:ash_quick_download`. The bytes are text, or not valid UTF-8 when `format`
  is `"bin"`. `:open` is an audited read, and the resource lists no context
  keys, so its rows keep `action_source` only.

  Its update policy is a filter on the record: whoever created the report may
  update it, and so may the actors it names in `reader_ids`.
  """
  use Ash.Resource,
    domain: AshQuick.Test.AuditDomain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
    attribute :reader_ids, {:array, :uuid}, public?: true, default: []
  end

  actions do
    defaults [:read, create: [:title, :reader_ids], update: [:title]]

    read :open do
      get? true
    end

    update :export do
      accept []
      require_atomic? false

      argument :format, :string, default: "csv"
      # Set by the hook, never by the caller.
      argument :filename, :string

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.before_transaction(fn changeset ->
          format = Ash.Changeset.get_argument(changeset, :format)

          changeset
          |> Ash.Changeset.force_set_argument(:filename, "report.#{format}")
          |> Ash.Changeset.set_context(%{copy: AshQuick.Test.Report.bytes(format)})
        end)
        |> Ash.Changeset.after_action(fn changeset, record ->
          {:ok,
           Ash.Resource.put_metadata(record, :ash_quick_download, %{
             data: changeset.context.copy,
             filename: Ash.Changeset.get_argument(changeset, :filename),
             content_type: "application/octet-stream"
           })}
        end)
      end
    end
  end

  policies do
    policy action_type([:read, :create]) do
      authorize_if always()
    end

    policy action_type(:update) do
      authorize_if expr(inserted_by_id == ^actor(:id) or ^actor(:id) in reader_ids)
    end
  end

  ash_quick do
    audit do
      store AshQuick.Test.JsonAuditStore
      read_actions [:open]
    end

    display do
      label :title
    end

    liveness do
      enabled? false
    end
  end

  @doc false
  def bytes("bin"), do: <<0xFF, 0xFE, 0x00>> <> "zq-report-body"
  def bytes(_format), do: "zq-report-body"
end
