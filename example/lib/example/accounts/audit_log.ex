defmodule Example.Accounts.AuditLog do
  @moduledoc """
  One row per audited write — the store `:audit_resource` names.

  It is deliberately dumb on the write side: no validations, and a `:create`
  that accepts everything AshQuick hands it. The row is written in
  `after_batch`, inside the transaction of the write it describes, so anything
  that could refuse here would roll that write back — an audit table able to
  veto a business action is a liability rather than a record.

  Reading it is the other question, and that one does have a policy: an audit
  trail is exactly the sort of thing not everyone should be able to page
  through.
  """

  use Ash.Resource,
    domain: Example.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "audit_logs"
    repo Example.Repo

    references do
      reference :actor, on_delete: :restrict, on_update: :restrict
      reference :real_actor, on_delete: :restrict, on_update: :restrict
    end

    custom_indexes do
      # The trail for one record, which is what a details page asks for.
      index [:resource_id, :resource_name]
      index [:actor_id]
    end
  end

  resource do
    plural_name :audit_logs
  end

  actions do
    default_accept :*
    defaults [:create, :read]

    read :index do
      argument :search, :string

      prepare Example.Accounts.Preparations.AuditLogsSearch
      prepare build(sort: [id: :desc])

      pagination do
        keyset? true
        offset? true
        default_limit 20
        countable :by_default
      end
    end
  end

  policies do
    # Writes arrive from AshQuick's own change with `authorize?: false`, inside
    # the transaction of the write being recorded.
    policy action_type(:create) do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if Example.Checks.ActorIsAdmin
    end
  end

  ash_quick do
    liveness do
      # Append-only, and a refetch only refreshes rows already on screen — a new
      # row could never appear. Publishing would be traffic no page can act on.
      enabled? false
    end

    versioning do
      enabled? false
      reason("Append-only: no update or destroy action, so there is no write to lose.")
    end

    bookkeeping do
      # The row names the actor of the write it records in `actor_id`. Nothing
      # creates or updates the row itself — writing it *is* the act.
      created_by false
      updated_by false
    end
  end

  attributes do
    # Time-ordered, so the entries for one record read in the order they were
    # written. A v4 key would sort an update's row ahead of its create.
    uuid_v7_primary_key :id

    attribute :resource_name, :atom, allow_nil?: false, public?: true
    attribute :resource_id, :uuid, allow_nil?: false, public?: true
    attribute :action_type, :atom, allow_nil?: false, public?: true
    attribute :action_name, :atom, allow_nil?: false, public?: true
    attribute :attributes, :map, allow_nil?: false, public?: true
    attribute :arguments, :map, allow_nil?: false, public?: true
    attribute :context, :map, allow_nil?: false, public?: true

    attribute :ip, :string, allow_nil?: true, public?: true
    attribute :tenant, :uuid, allow_nil?: true, public?: true
  end

  relationships do
    belongs_to :actor, Example.Accounts.User do
      public? true
    end

    belongs_to :real_actor, Example.Accounts.User do
      public? true
      allow_nil? true
    end
  end

  calculations do
    # An entry is "what was done to what" — the pair a reader scans for. Both
    # are atoms on the way out of the column, so they are cast rather than
    # concatenated as they sit.
    calculate :display_name,
              :string,
              expr(string_join([type(action_name, :string), type(resource_name, :string)], " "))

    calculate :actor_name, :string, expr(actor.name)
  end
end
