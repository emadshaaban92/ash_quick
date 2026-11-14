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

defmodule Example.Test.HiddenChangesNote do
  @moduledoc """
  `Example.Accounts.AuditLog`'s table again, each row read as a note on the
  row its `resource_id` names, through a belongs_to on
  `Example.Test.HiddenChanges`: a map a field policy hides on some rows, on
  the far side of a relationship, which a map filter through it must not
  read back either.
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
  end

  relationships do
    belongs_to :subject, Example.Test.HiddenChanges,
      source_attribute: :resource_id,
      public?: true
  end
end
