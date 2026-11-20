defmodule Example.Test.TenantBroadcasts.Domain do
  @moduledoc "Holds the multitenant resources whose broadcasts stay in their tenant."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.TenantBroadcasts.Crate do
  @moduledoc """
  A crate held per store under `strategy :attribute`, with no `global?`: no
  reader may read one without a store, so no write of one is published on the
  bare topics.
  """
  use Ash.Resource,
    domain: Example.Test.TenantBroadcasts.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, :destroy, create: [:name], update: [:name]]
  end

  multitenancy do
    strategy :attribute
    attribute :store_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :store_id, :uuid, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
  end
end

defmodule Example.Test.TenantBroadcasts.Locker do
  @moduledoc """
  A locker held per tenant under `strategy :context`: the tenant is the
  changeset's, not an attribute's. Not audited, so a tenant need not fit the
  audit store's `:uuid` column: the tenants here include one containing the
  topic delimiter.
  """
  use Ash.Resource,
    domain: Example.Test.TenantBroadcasts.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, :destroy, create: [:name], update: [:name]]
  end

  ash_quick do
    audit do
      enabled? false
    end
  end

  multitenancy do
    strategy :context
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
  end
end

defmodule Example.Test.TenantBroadcasts.Bin do
  @moduledoc """
  A bin held per store under `strategy :attribute`, with no `global?`, but
  with read actions that cross stores: `:anywhere` (`:allow_global`), read by
  platform staff with no store, and `:across` (`:bypass`), which shows every
  store's bins to a reader in one.
  """
  use Ash.Resource,
    domain: Example.Test.TenantBroadcasts.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, :destroy, create: [:name], update: [:name]]

    read :anywhere do
      multitenancy :allow_global
    end

    read :across do
      multitenancy :bypass
    end
  end

  multitenancy do
    strategy :attribute
    attribute :store_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :store_id, :uuid, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
  end
end
