defmodule Example.Catalog.Store do
  @moduledoc """
  A shop whose catalogue is its own. The tenant everything else is scoped to.

  Not multitenant itself — a tenant is the thing being partitioned *by*, and a
  list of tenants that could only be read from inside one would be unreadable.

  A user belongs to at most one store (`Example.Accounts.User.store`), and
  `Example.Scope` puts that on every action as the Ash tenant. From there
  `Example.Catalog.Product`'s `multitenancy` block does the rest: a reader with
  a store sees that store's products and no others, and a reader with none —
  the platform staff who administer this place — sees every store's.
  """

  use Ash.Resource,
    domain: Example.Catalog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "stores"
    repo Example.Repo

    references do
      reference :created_by, on_delete: :restrict, on_update: :restrict
      reference :updated_by, on_delete: :restrict, on_update: :restrict
    end
  end

  resource do
    plural_name :stores
  end

  code_interface do
    define :create
    define :read_all, action: :read
  end

  actions do
    default_accept [:code, :name]
    defaults [:create, :read, :update, :destroy]

    read :index do
      argument :search, :string

      prepare Example.Catalog.Preparations.StoresSearch
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
    # Opening and closing a store is platform work, not something a shopkeeper
    # does to their own.
    policy action_type([:create, :update, :destroy]) do
      authorize_if Example.Checks.ActorIsAdmin
    end

    # Readable by everyone signed in, because a user's own store is rendered by
    # name wherever they are shown.
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
