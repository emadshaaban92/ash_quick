defmodule AshQuick.Test.Accounts do
  @moduledoc """
  The domain the actor resource belongs to.

  Separate from every other fixture domain on purpose: an actor relationship
  crosses domains in every real host, and `AshQuick.Bookkeeping.Transformer`
  reads the destination's domain off the resource rather than off the source.
  A probe in one domain stamping an actor in another is what pins that.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshQuick.Test.AuditLog do
  @moduledoc """
  The store `:audit_resource` points at for the suite — every column
  `AshQuick.Audit.Row` fills, and a `:create` that takes all of them.

  What a host's own audit table is, minus the data layer: the assertions are
  about the row AshQuick builds, not about where it lands.
  """
  use Ash.Resource, domain: AshQuick.Test.Accounts, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    # Time-ordered, as a host's own audit table is: a trail is read in the order
    # it was written, and a v4 key would sort the entries for one record
    # arbitrarily — an update's row ahead of the create that preceded it.
    uuid_v7_primary_key :id
    attribute :resource_name, :atom, public?: true
    attribute :resource_id, :uuid, public?: true
    attribute :action_type, :atom, public?: true
    attribute :action_name, :atom, public?: true
    attribute :attributes, :map, public?: true
    attribute :arguments, :map, public?: true
    attribute :context, :map, public?: true
    # Optional on a store, and present here: the before and after of everything
    # the write changed.
    attribute :changes, :map, public?: true
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

defmodule AshQuick.Test.Actor do
  @moduledoc """
  Stands in for the host's user resource: what `:actor_resource` points at.

  It carries the extension, an authorizer and an audit trail because the actor
  resource may not go without any of the three — `AshQuick.Impersonation` is
  generated onto it, and `AshQuick.ImpersonationVerifierTest` drives what
  happens when one is missing.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Accounts,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
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

  policies do
    policy always() do
      authorize_if always()
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

    # Nothing writes an actor here, so it carries none of the four and says so.
    bookkeeping do
      created_at false
      updated_at false
      created_by false
      updated_by false
    end
  end
end

defmodule AshQuick.Test.Tenant do
  @moduledoc """
  A second resource an actor relationship could point at by mistake.

  `belongs_to :created_by, AshQuick.Test.Tenant` reads like bookkeeping and is
  not — only the name suggests it is about the actor, and the name is the one
  thing that must not decide. `AshQuick.BookkeepingVerifierTest` probes with it.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Accounts,
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
      created_at false
      updated_at false
      created_by false
      updated_by false
    end
  end
end

defmodule AshQuick.Test.PlainRecord do
  @moduledoc """
  A resource with no AshQuick extension at all.

  Stands in for the parts of a host that never reach a QuickView. Pointing
  `:actor_resource` at one is the mistake `AshQuick.Bookkeeping.Verifier`
  refuses: nothing could ask it what a record is called.
  """
  use Ash.Resource, domain: AshQuick.Test.Accounts, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    create_timestamp :created_at
  end

  actions do
    defaults [:read, :create]
  end
end
