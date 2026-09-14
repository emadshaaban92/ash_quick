defmodule Example.Catalog.Brand do
  @moduledoc """
  The plainest resource in the app: a code and a name.

  It carries nothing but the extension's defaults, which makes it what the
  optimistic lock is driven against — a stale write here fails because of
  versioning and not because of anything this resource says.
  """

  use Ash.Resource,
    domain: Example.Catalog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "brands"
    repo Example.Repo

    references do
      reference :created_by, on_delete: :restrict, on_update: :restrict
      reference :updated_by, on_delete: :restrict, on_update: :restrict
    end
  end

  resource do
    plural_name :brands
  end

  code_interface do
    define :create
    define :read_all, action: :read
    define :update
    define :destroy
  end

  actions do
    default_accept [:code, :name]
    defaults [:create, :read, :update, :destroy]

    read :index do
      argument :search, :string

      prepare Example.Catalog.Preparations.BrandsSearch
      prepare build(sort: [name: :asc])

      pagination do
        keyset? true
        offset? true
        default_limit 20
        countable :by_default
      end
    end
  end

  policies do
    policy action_type([:create, :update, :destroy]) do
      authorize_if Example.Checks.ActorCanWrite
    end

    policy action_type(:read) do
      authorize_if actor_present()
    end
  end

  ash_quick do
    activation do
      enabled? true
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
  end

  identities do
    identity :code, [:code]
  end
end
