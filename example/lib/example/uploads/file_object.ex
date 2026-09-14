defmodule Example.Uploads.FileObject do
  @moduledoc """
  One row per storage key: where that object currently is.

  The row exists from **presign**, not from save. Uploads are `auto_upload:
  true`, so bytes land as soon as a file is picked — an object the host heard
  about only at save would be one it never heard of for every abandoned form.
  That is why `resource_id` is nullable: a create form has no record to point
  at yet, and the link is stamped again when the record is saved.

  `key` is the serving key and is unique, because "the row for key K" has to be
  exactly one row. The bytes live at `Example.Uploads.Quarantine.key/1` of it
  until something calls `release!/1`.

  `accepts` and `max_bytes` are copied off the field at presign because they
  cannot be recovered later: a key alone does not say which Ash type constraint
  produced it.

  Writes come from the storage seam with authorization off — the object arrives
  before anything has decided whether the actor may save the record — so the
  policies here can stay closed.
  """

  use Ash.Resource,
    domain: Example.Uploads,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "file_objects"
    repo Example.Repo

    references do
      reference :actor, on_delete: :nilify, on_update: :update
    end

    custom_indexes do
      index [:state]
      index [:referenced_at]
    end
  end

  resource do
    plural_name :file_objects
  end

  code_interface do
    define :take_custody, action: :take_custody
    define :release, action: :release
    define :reject, action: :reject
    define :reference, action: :reference
    define :by_keys, action: :by_keys, args: [:keys]
  end

  actions do
    defaults [:read, :destroy]

    read :index do
      argument :search, :string

      prepare Example.Uploads.Preparations.FileObjectsSearch
      prepare build(sort: [id: :desc])

      pagination do
        keyset? true
        offset? true
        default_limit 20
        countable :by_default
      end
    end

    read :by_keys do
      argument :keys, {:array, :string}, allow_nil?: false

      filter expr(key in ^arg(:keys))
    end

    # Upserts, because a surface may present the same key twice. State is left
    # alone on the second pass: a key already settled is not un-settled.
    create :take_custody do
      upsert? true
      upsert_identity :unique_key

      upsert_fields [
        :source,
        :accepts,
        :max_bytes,
        :content_type,
        :byte_size,
        :original_filename,
        :resource_name,
        :resource_id,
        :actor_id,
        :updated_at
      ]

      accept [
        :key,
        :source,
        :accepts,
        :max_bytes,
        :content_type,
        :byte_size,
        :original_filename,
        :resource_name,
        :resource_id,
        :actor_id
      ]
    end

    # `require_atomic? false` throughout: the audit change builds its row from
    # the changeset, which the atomic path never produces.
    update :release do
      accept []
      require_atomic? false

      change set_attribute(:state, :ready)
    end

    update :reject do
      accept []
      require_atomic? false

      change set_attribute(:state, :rejected)
    end

    # Stamped when a saved record first names this key. The timestamp is not
    # refreshed on a later save: "was this ever attached to anything" is the
    # question, and the first answer settles it.
    update :reference do
      accept [:resource_name, :resource_id]

      require_atomic? false

      change fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :referenced_at) do
          nil ->
            Ash.Changeset.force_change_attribute(changeset, :referenced_at, DateTime.utc_now())

          _already ->
            changeset
        end
      end
    end
  end

  policies do
    # Stamped by `Example.Uploads.ObjectStore.object_referenced/3` with
    # `authorize?: false`, and by nothing else. Left authorizable it renders as
    # a button on the details page, and because it takes inputs that button
    # patches to `/file_objects/:id/reference` — a route this read-only page
    # does not serve. `mix ash_quick.check` reports exactly that.
    policy action(:reference) do
      forbid_if always()
    end

    # Custody is taken and settled by the pipeline with `authorize?: false`,
    # inside whatever transaction is running at the time.
    policy action_type([:create, :update, :destroy]) do
      authorize_if Example.Checks.ActorIsAdmin
    end

    policy action_type(:read) do
      authorize_if actor_present()
    end
  end

  ash_quick do
    display do
      label :key
    end

    versioning do
      enabled? false
      reason("Operational state the upload pipeline advances and a person only reads.")
    end

    bookkeeping do
      # `:actor` above already records who handed the object over, and custody
      # is frequently taken with nobody behind it — a second pair of actor
      # columns would only be a `allow_nil? false` the seam cannot satisfy.
      created_by false
      updated_by false
    end
  end

  attributes do
    uuid_v7_primary_key :id

    # The serving key, never the quarantine key the bytes are at meanwhile.
    attribute :key, :string, allow_nil?: false, public?: true

    attribute :state, :atom,
      allow_nil?: false,
      public?: true,
      default: :processing,
      constraints: [one_of: [:processing, :ready, :rejected]]

    attribute :source, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:upload_form]]

    attribute :accepts, {:array, :atom},
      allow_nil?: true,
      public?: true,
      constraints: [items: [one_of: [:image, :video]]]

    attribute :max_bytes, :integer, allow_nil?: true, public?: true, constraints: [min: 0]

    attribute :content_type, :string, allow_nil?: true, public?: true
    attribute :byte_size, :integer, allow_nil?: true, public?: true, constraints: [min: 0]

    attribute :original_filename, :string, allow_nil?: true, public?: true

    # A hint, and a stale one the moment the record's attachment is replaced:
    # record → key is the authoritative direction, and this points the other way
    # for the cold paths only. It cannot be a foreign key, being polymorphic
    # across every resource that carries an attachment field.
    attribute :resource_name, :atom, allow_nil?: true, public?: true
    attribute :resource_id, :uuid, allow_nil?: true, public?: true

    # Set when a saved record first referenced this key. Nil is the
    # abandoned-upload case.
    attribute :referenced_at, :utc_datetime_usec, allow_nil?: true, public?: true
  end

  relationships do
    # Nullable: an object can arrive from a surface with nobody behind it.
    belongs_to :actor, Example.Accounts.User do
      domain Example.Accounts
      public? true
      allow_nil? true
    end
  end

  calculations do
    calculate :display_name, :string, expr(key)
    calculate :actor_name, :string, expr(actor.name)
  end

  identities do
    identity :unique_key, [:key]
  end
end
