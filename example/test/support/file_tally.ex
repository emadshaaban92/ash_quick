defmodule Example.Test.FileTally.Domain do
  @moduledoc "Holds the resource whose counter a change works out in the database."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.FileTally do
  @moduledoc """
  `Example.Uploads.FileObject`'s table, read and written by a resource whose
  updates set attributes from expressions the database works out.

  `byte_size` is declared required here, with a floor — a required counter —
  which is what makes Ash wrap an expression for it in a required check and a
  check per constraint on its way to the database. Audited and unversioned, so
  every update runs as one `UPDATE ... RETURNING`, and its bookkeeping
  `updated_at` is an update default, which on that path is an expression too.
  """
  use Ash.Resource,
    domain: Example.Test.FileTally.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshQuick]

  postgres do
    table "file_objects"
    repo Example.Repo
  end

  actions do
    defaults [:read, create: [:key]]

    update :bump do
      accept []
      change atomic_update(:byte_size, expr(byte_size + 1))
    end

    # Something Postgres alone can answer, and that could come to nil.
    update :measure do
      accept []
      change atomic_update(:byte_size, expr(fragment("length(?)", key)))
    end

    update :name_after_key do
      accept []
      change atomic_update(:original_filename, expr(key <> ".pdf"))
    end
  end

  ash_quick do
    display do
      label :key
    end

    versioning do
      enabled? false
    end

    bookkeeping do
      inserted_at false
      inserted_by false
      updated_by false
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :key, :string, allow_nil?: false, public?: true
    attribute :source, :atom, allow_nil?: false, public?: true, default: :upload

    attribute :byte_size, :integer,
      allow_nil?: false,
      public?: true,
      default: 0,
      constraints: [min: 0]

    attribute :original_filename, :string, allow_nil?: true, public?: true
  end
end
