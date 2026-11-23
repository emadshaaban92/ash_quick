defmodule Example.Catalog.ProductLabel do
  @moduledoc """
  The join between `Example.Catalog.Product` and its labels.

  It does not take the AshQuick extension: no page renders it, and a row is
  only a pair of keys, written and removed with the product's own write.
  """

  use Ash.Resource,
    domain: Example.Catalog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "product_labels"
    repo Example.Repo

    references do
      reference :product, on_delete: :delete, on_update: :restrict
      reference :label, on_delete: :delete, on_update: :restrict
    end
  end

  actions do
    defaults [:read, :destroy, create: [:product_id, :label_id]]
  end

  # Whoever may change the product may change what it is labelled with.
  policies do
    policy action_type([:create, :destroy]) do
      authorize_if Example.Checks.ActorCanWrite
    end

    policy action_type(:read) do
      authorize_if actor_present()
    end
  end

  relationships do
    belongs_to :product, Example.Catalog.Product,
      primary_key?: true,
      allow_nil?: false,
      public?: true

    belongs_to :label, Example.Catalog.Label,
      primary_key?: true,
      allow_nil?: false,
      public?: true
  end
end
