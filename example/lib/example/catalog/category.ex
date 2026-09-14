defmodule Example.Catalog.Category do
  @moduledoc """
  A self-referencing tree with one image.

  Two things here that `Brand` does not have. The `:parent` relationship is what
  a BelongsTo dropdown is rendered from — and what makes the resource its own
  dropdown destination, so its lookup action has to satisfy the contract for a
  page other than its own. And `:image` is an `:attachment` declared
  `visibility: :private`, which is the other half of the key-prefix pair the
  presign tests assert.
  """

  use Ash.Resource,
    domain: Example.Catalog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "categories"
    repo Example.Repo

    references do
      reference :parent, on_delete: :restrict, on_update: :restrict
      reference :created_by, on_delete: :restrict, on_update: :restrict
      reference :updated_by, on_delete: :restrict, on_update: :restrict
    end
  end

  resource do
    plural_name :categories
  end

  code_interface do
    define :create
    define :read_all, action: :read
    define :update
  end

  actions do
    default_accept [:code, :name, :image, :parent_id]
    defaults [:create, :read, :update, :destroy]

    read :index do
      argument :search, :string

      prepare Example.Catalog.Preparations.CategoriesSearch
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

    # Private, so the object is served through a signed URL rather than straight
    # from the bucket — and so its key lands under `private/categories/`.
    attribute :image, :attachment,
      public?: true,
      allow_nil?: true,
      constraints: [visibility: :private, accepts: [:image], max_size_mb: 10]
  end

  relationships do
    belongs_to :parent, __MODULE__ do
      public? true
      allow_nil? true
    end

    has_many :children, __MODULE__ do
      public? true
      destination_attribute :parent_id
    end
  end

  identities do
    identity :code, [:code]
  end
end
