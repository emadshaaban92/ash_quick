defmodule Example.Test.FilterFields.Domain do
  @moduledoc "Holds the resource the list's filter is exercised on."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.FilterFields do
  @moduledoc """
  A resource for the list's filter: a code to match the start of, a timestamp
  to compare, a salary only an admin may see, which the filter offers to no
  one else, a flag picked as Yes or No, and tags, which it offers to no one.

  In ETS rather than Postgres, so Starts With is read by Ash itself rather
  than by a SQL `LIKE`.
  """
  use Ash.Resource,
    domain: Example.Test.FilterFields.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  field_policies do
    field_policy :salary do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [:read, create: [:code, :stamped_at, :salary, :active]]

    read :index do
      argument :search, :string

      pagination do
        keyset? true
        offset? true
        default_limit 250
        countable :by_default
      end
    end
  end

  policies do
    policy always() do
      authorize_if always()
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
    attribute :stamped_at, :utc_datetime_usec, public?: true
    attribute :salary, :integer, public?: true
    attribute :active, :boolean, public?: true
    # A list, which the filter does not offer.
    attribute :tags, {:array, :string}, public?: true, default: []
  end
end

defmodule Example.Test.FilterFieldsLive.Quick do
  @moduledoc """
  The page over `Example.Test.FilterFields`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.FilterFields,
    list: [fields: [:code, :stamped_at, :active]],
    details: [fields: [:code, :stamped_at]]
end
