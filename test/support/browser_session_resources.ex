defmodule AshQuick.Test.BrowserSessions.Domain do
  @moduledoc """
  Holds `AshQuick.Test.BrowserSessions.Person`, the actor resource the Live
  Users register is narrowed over in the library's tests.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshQuick.Test.BrowserSessions.Person do
  @moduledoc """
  An actor resource partitioned by organisation, whose `:impersonate` policy
  is a role check and nothing else.

  That is the shape that lets a tenant's admin through the register's
  "may stand in for anybody" gate: a role check needs no record, so it passes
  for them whichever tenant a session runs in. Reads are open, so the tenant
  is the only thing narrowing what they see. Not `global?`, so a read with no
  tenant is refused outright.
  """
  use Ash.Resource,
    domain: AshQuick.Test.BrowserSessions.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  multitenancy do
    strategy :attribute
    attribute :org
  end

  actions do
    defaults [:read, create: [:org, :role]]

    update :impersonate do
      accept []
    end
  end

  policies do
    policy action(:impersonate) do
      authorize_if actor_attribute_equals(:role, :tenant_admin)
    end

    policy action_type([:read, :create]) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :org, :string, allow_nil?: false, public?: true
    attribute :role, :atom, public?: true
  end
end
