defmodule Example.Test.HiddenChanges.Domain do
  @moduledoc "Holds the resource whose map a field policy hides on some rows."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.HiddenChanges do
  @moduledoc """
  `Example.Accounts.AuditLog`'s table, read by a resource whose `changes` a
  field policy shows to an admin on every row and to anyone else only on a
  row whose `ip` is `"shown"`: a map hidden on some rows, which a map filter
  must not read back.
  """
  use Ash.Resource,
    domain: Example.Test.HiddenChanges.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "audit_logs"
    repo Example.Repo
    migrate? false
  end

  field_policies do
    field_policy :changes do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if expr(ip == "shown")
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [:read]
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :resource_id, :uuid, public?: true
    attribute :changes, :map, public?: true
    attribute :ip, :string, public?: true
  end
end
