defmodule Example.Catalog.Product do
  @moduledoc """
  The resource the list, form and details pages are worth looking at over.

  Between them its fields cover most of what a QuickView has to render: two
  BelongsTo dropdowns, a `Money` column, long text, an array of atoms, and an
  array of embedded attachments with an upload behind each one.
  """

  use Ash.Resource,
    domain: Example.Catalog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "products"
    repo Example.Repo

    references do
      reference :brand, on_delete: :restrict, on_update: :restrict
      reference :category, on_delete: :restrict, on_update: :restrict
      reference :created_by, on_delete: :restrict, on_update: :restrict
      reference :updated_by, on_delete: :restrict, on_update: :restrict
    end
  end

  resource do
    plural_name :products
  end

  code_interface do
    define :create
    define :read_all, action: :read
    define :update
    define :reprice, args: [:price]
  end

  actions do
    default_accept [:sku, :name, :description, :price, :tags, :images, :brand_id, :category_id]
    defaults [:create, :read, :update, :destroy]

    read :index do
      argument :search, :string

      prepare Example.Catalog.Preparations.ProductsSearch
      prepare build(sort: [name: :asc])

      pagination do
        keyset? true
        offset? true
        default_limit 20
        countable :by_default
      end
    end

    # A second create action beside the generic one. `quick_view/3` serves no
    # `/<action>` route, so `?action=quick_add` on the create path is the only
    # way to reach it — which is why a canonical URL may correct the query but
    # never the path.
    create :quick_add do
      accept [:sku, :name, :price, :brand_id, :category_id]
    end

    # A named update beside the generic one, so a QuickView has a row action to
    # offer and the audit trail records *repricing* rather than "update".
    update :reprice do
      # Nothing but the argument: without `accept []` the action would inherit
      # `default_accept` and its form would offer every field the generic update
      # form does, which is not what "reprice" means.
      accept []
      argument :price, :money, allow_nil?: false

      require_atomic? false

      change set_attribute(:price, arg(:price))

      change fn changeset, context ->
        Ash.Changeset.after_action(changeset, fn changeset, product ->
          Example.Catalog.PriceChange.create(
            %{
              product_id: product.id,
              from_price: changeset.data.price,
              to_price: product.price
            },
            actor: context.actor,
            authorize?: false
          )

          {:ok, product}
        end)
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

    attribute :sku, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true

    # `:text` renders as a textarea on the form and is truncated in the list —
    # the difference between it and `:string` is entirely about the surface.
    attribute :description, :text, allow_nil?: true, public?: true

    attribute :price, :money do
      allow_nil? false
      public? true
      constraints ex_money_opts: [default_currency: :USD, only: [:USD, :EUR]]
    end

    attribute :tags, {:array, :atom},
      allow_nil?: true,
      public?: true,
      default: [],
      constraints: [items: [one_of: [:new, :sale, :clearance, :staff_pick]]]

    attribute :images, {:array, Example.Catalog.ProductImage},
      allow_nil?: true,
      public?: true,
      default: []
  end

  relationships do
    belongs_to :brand, Example.Catalog.Brand do
      public? true
      allow_nil? false
    end

    belongs_to :category, Example.Catalog.Category do
      public? true
      allow_nil? false
    end

    has_many :price_changes, Example.Catalog.PriceChange do
      public? true
      sort id: :desc
    end
  end

  identities do
    identity :sku, [:sku]
  end
end
