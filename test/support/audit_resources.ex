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
    defaults [:read, :create]

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
  end

  ash_quick do
    audit do
      record_sensitive [:masked_card_number]
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
      created_at false
      updated_at false
      created_by false
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
      created_at false
      updated_at false
      created_by false
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
