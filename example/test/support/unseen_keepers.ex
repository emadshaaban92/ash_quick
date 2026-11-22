defmodule Example.Test.UnseenKeepers.Domain do
  @moduledoc "Holds the resources of a belongs-to whose record a reader may not see."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.UnseenKeepers.Keeper do
  @moduledoc """
  Who keeps an `Example.Test.UnseenKeepers`, and a flag hiding the keeper
  from anyone but an admin. Searched by name.
  """
  use Ash.Resource,
    domain: Example.Test.UnseenKeepers.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  actions do
    defaults [:read, create: [:name, :hidden]]

    read :index do
      argument :search, :string
      filter expr(is_nil(^arg(:search)) or contains(name, ^arg(:search)))
      pagination offset?: true, required?: false, default_limit: 20
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if expr(hidden == false)
    end

    policy action_type(:create) do
      authorize_if always()
    end
  end

  ash_quick do
    display do
      label :name
    end

    versioning do
      enabled? false
    end

    audit do
      enabled? false
    end

    bookkeeping do
      inserted_at false
      inserted_by false
      updated_at false
      updated_by false
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :hidden, :boolean, default: false, public?: true
  end
end

defmodule Example.Test.UnseenKeepers do
  @moduledoc """
  A record kept by an `Example.Test.UnseenKeepers.Keeper`, whose update form
  picks the keeper and writes a note, and a page over it. A reader who may
  not see its keeper can still edit the note.

  In ETS rather than Postgres: nothing here is about what lands in a table.
  """
  use Ash.Resource,
    domain: Example.Test.UnseenKeepers.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:code, :note, :keeper_id]]

    update :update do
      primary? true
      accept [:note, :keeper_id]
    end

    read :index do
      argument :search, :string
      pagination offset?: true, required?: false, default_limit: 20
    end
  end

  ash_quick do
    display do
      label :code
    end

    versioning do
      enabled? false
    end

    audit do
      enabled? false
    end

    bookkeeping do
      inserted_at false
      inserted_by false
      updated_at false
      updated_by false
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true
    attribute :note, :string, public?: true
  end

  relationships do
    belongs_to :keeper, Example.Test.UnseenKeepers.Keeper do
      public? true
    end
  end
end

defmodule Example.Test.UnseenKeepersLive.Quick do
  @moduledoc """
  The page over `Example.Test.UnseenKeepers`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.UnseenKeepers,
    list: [fields: [:code]],
    details: [fields: [:code]]
end
