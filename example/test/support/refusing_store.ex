defmodule AshQuick.AuditTest.Domain do
  @moduledoc "Holds the audit store that refuses every entry."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshQuick.AuditTest.RefusingStore do
  @moduledoc """
  An audit store whose `:create` always fails.

  It exists so a test can show what happens to the write being recorded when
  the entry cannot be written: the store sits on the critical path, inside the
  action's transaction, and the record goes back with it.
  """
  use Ash.Resource, domain: AshQuick.AuditTest.Domain, data_layer: AshPostgres.DataLayer

  postgres do
    # The real store's table. Nothing is ever written to it from here — the
    # action refuses before the insert — and pointing somewhere else would need
    # a migration for a row that never lands.
    table "audit_logs"
    repo Example.Repo
  end

  actions do
    default_accept :*
    defaults [:read]

    # What refuses in production is a column that is gone, a foreign key to a
    # deleted actor, or the database being down; a validation stands in for all
    # of those, because what the store said is what has to reach the caller
    # either way.
    create :create do
      validate fn _changeset, _context ->
        {:error, field: :attributes, message: "audit store unreachable"}
      end
    end
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
end
