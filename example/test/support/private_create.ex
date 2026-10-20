defmodule Example.Test.PrivateCreate.Domain do
  @moduledoc "Holds the resource whose `:create` is the host's own."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.PrivateCreate do
  @moduledoc """
  A resource whose `:create` is private, and a page over it routed with every
  shape, `/create` included.

  No authorizer, so `Ash.can?` allows the create: what keeps the New button
  off the list is that the action is private, which the create page refuses.

  In ETS rather than Postgres: nothing here is about what lands in a table.
  """
  use Ash.Resource,
    domain: Example.Test.PrivateCreate.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read]

    create :create do
      public? false
      accept [:code]
    end

    read :index do
      argument :search, :string

      pagination do
        keyset? true
        offset? true
        default_limit 20
        countable :by_default
      end
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
  end
end

defmodule Example.Test.PrivateCreateLive.Quick do
  @moduledoc """
  The page over `Example.Test.PrivateCreate`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.PrivateCreate,
    list: [fields: [:code]],
    details: [fields: [:code]]
end
