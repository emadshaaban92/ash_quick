defmodule Example.Test.NamedRows.Domain do
  @moduledoc "Holds the resource whose list names each row's checkbox."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.NamedRows do
  @moduledoc """
  A resource labelled by a calculation its list draws no column for, so the
  list loads the label for its row checkboxes alone. A row with no name has
  no label, and a `private` row's label is withheld by a field policy: both
  name their checkbox by id instead.

  In ETS rather than Postgres: nothing here is about what lands in a table.
  """
  use Ash.Resource,
    domain: Example.Test.NamedRows.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  field_policies do
    field_policy :display_name do
      forbid_if expr(private == true)
      authorize_if always()
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [:read, create: [:code, :name, :private]]

    read :index do
      argument :search, :string
      prepare build(sort: [code: :asc])

      pagination do
        keyset? true
        offset? true
        default_limit 20
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
      label :display_name
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
    attribute :name, :string, public?: true
    attribute :private, :boolean, allow_nil?: false, default: false, public?: true
  end

  calculations do
    calculate :display_name, :string, expr(name), public?: true
  end
end

defmodule Example.Test.NamedRowsLive.Quick do
  @moduledoc """
  The page over `Example.Test.NamedRows`, routed only in the test build — see
  the `:test_routes` block in `ExampleWeb.Router`. Its list draws the code
  alone, not the label.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.NamedRows,
    list: [fields: [:code]],
    details: [fields: [:code, :name]]
end

defmodule Example.Test.NamedRows.Counted do
  @moduledoc """
  A record labelled by a count of `Example.Test.ShelvedCrates.Item`s, which
  are held per tenant: a list read with no tenant cannot load the label, so
  it skips it and names each row's checkbox by id rather than failing.
  """
  use Ash.Resource,
    domain: Example.Test.NamedRows.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:code]]

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
      label :item_count
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

  relationships do
    has_many :items, Example.Test.ShelvedCrates.Item,
      destination_attribute: :shelf_id,
      public?: true
  end

  aggregates do
    count :item_count, :items, public?: true
  end
end

defmodule Example.Test.NamedRowsCountedLive.Quick do
  @moduledoc """
  The page over `Example.Test.NamedRows.Counted`, routed only in the test
  build. Its list draws the code alone, not the label.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.NamedRows.Counted,
    list: [fields: [:code]],
    details: [fields: [:code]]
end
