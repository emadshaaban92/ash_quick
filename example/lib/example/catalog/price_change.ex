defmodule Example.Catalog.PriceChange do
  @moduledoc """
  What a product used to cost and what it costs now — written by
  `Example.Catalog.Product`'s `:reprice` action and never by a person.

  It is here for the half-declared bookkeeping case. Nothing updates a row, so
  it carries `created_at` / `created_by` and neither of the other two, and a
  details page over it therefore renders "Created by X on Y" with no second
  half. `AshQuick.LiveView.DetailsUtils.actor_load/1` is built from the same
  declaration, which is why it asks for one relationship here and two on a
  product.
  """

  use Ash.Resource,
    domain: Example.Catalog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "price_changes"
    repo Example.Repo

    references do
      reference :product, on_delete: :delete, on_update: :restrict
      reference :created_by, on_delete: :restrict, on_update: :restrict
    end
  end

  resource do
    plural_name :price_changes
  end

  code_interface do
    define :create
    define :read_all, action: :read
  end

  actions do
    default_accept [:product_id, :from_price, :to_price]
    defaults [:create, :read]

    read :index do
      argument :search, :string

      prepare Example.Catalog.Preparations.PriceChangesSearch
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
    policy action_type(:create) do
      authorize_if Example.Checks.ActorCanWrite
    end

    policy action_type(:read) do
      authorize_if actor_present()
    end
  end

  ash_quick do
    liveness do
      # Append-only: a refetch only refreshes rows already on screen, so a new
      # row could never appear and publishing would be traffic nothing acts on.
      enabled? false
    end

    versioning do
      enabled? false
      reason("Nothing updates a row, so there is no concurrent write to lose.")
    end

    bookkeeping do
      updated_at false
      updated_by false
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :from_price, :money do
      public? true
      constraints ex_money_opts: [default_currency: :USD, only: [:USD, :EUR]]
    end

    attribute :to_price, :money do
      allow_nil? false
      public? true
      constraints ex_money_opts: [default_currency: :USD, only: [:USD, :EUR]]
    end
  end

  relationships do
    belongs_to :product, Example.Catalog.Product do
      public? true
      allow_nil? false
    end
  end

  calculations do
    # A row is read as the repricing *of* something; the amounts are Money,
    # which is not something a label can carry.
    calculate :display_name, :string, expr(product.name)
  end
end
