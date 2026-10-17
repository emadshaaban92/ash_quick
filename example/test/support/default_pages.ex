defmodule Example.Test.DefaultPages.Domain do
  @moduledoc "Holds the resource whose list action opens at two rows."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.DefaultPages do
  @moduledoc """
  A resource whose list action opens at two rows and allows up to five, and a
  page over it.

  A QuickView list nobody sized reads its action's `default_limit`. Every list
  in this application sets 20, the same number the page falls back to, so the
  case is built here with a default that tells the two apart.

  In ETS rather than Postgres, like `Example.Test.SmallPages`. The table is
  shared, so only `ExampleWeb.PageDefaultTest` writes to it.
  """
  use Ash.Resource,
    domain: Example.Test.DefaultPages.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:code]]

    read :index do
      argument :search, :string

      prepare build(sort: [code: :asc])

      pagination do
        keyset? true
        offset? true
        default_limit 2
        max_page_size 5
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

defmodule Example.Test.DefaultPagesLive.Quick do
  @moduledoc """
  The page over `Example.Test.DefaultPages`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.DefaultPages,
    list: [fields: [:code]],
    details: [fields: [:code]]
end
