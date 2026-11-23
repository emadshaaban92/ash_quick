defmodule Example.Catalog.Label do
  @moduledoc """
  A word a product is labelled with, picked by its name on the product form.

  Nobody adds one here: `Example.Catalog.Product`'s `:labels` argument
  relates the names that match and creates the rest, so the product form's
  picker offers to add a name it does not find. Only an admin may create one,
  so an editor's picker offers the labels there are and nothing new.

  The name is a `ci_string`, unique in any case, so "kayak" picks "Kayak"
  rather than adding a second one.
  """

  use Ash.Resource,
    domain: Example.Catalog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "labels"
    repo Example.Repo

    references do
      reference :inserted_by, on_delete: :restrict, on_update: :restrict
      reference :updated_by, on_delete: :restrict, on_update: :restrict
    end
  end

  resource do
    plural_name :labels
  end

  code_interface do
    define :create
    define :read_all, action: :read
  end

  actions do
    default_accept [:name]
    defaults [:create, :read, :update, :destroy]

    read :index do
      argument :search, :string

      prepare Example.Catalog.Preparations.LabelsSearch
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
    policy action_type(:create) do
      authorize_if Example.Checks.ActorIsAdmin
    end

    policy action_type([:update, :destroy]) do
      authorize_if Example.Checks.ActorCanWrite
    end

    policy action_type(:read) do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :ci_string, allow_nil?: false, public?: true
  end

  identities do
    identity :name, [:name]
  end
end
