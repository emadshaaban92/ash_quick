defmodule Example.Test.SmallPages.Domain do
  @moduledoc "Holds the resource whose list action reads at most three rows."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.SmallPages do
  @moduledoc """
  A resource whose list action caps a page at three rows, and a page over it.

  A QuickView list holds `?limit=` to its action's `max_page_size`. Every list
  in this application keeps Ash's default of 250, which a test would need 251
  rows to see past, so the case is built here with a ceiling a handful of rows
  can reach.

  In ETS rather than Postgres, like `Example.Test.DigitsOnly`. The table is
  shared, so only `ExampleWeb.PageCeilingTest` writes to it.
  """
  use Ash.Resource,
    domain: Example.Test.SmallPages.Domain,
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
        default_limit 3
        max_page_size 3
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

defmodule Example.Test.SmallPagesLive.Quick do
  @moduledoc """
  The page over `Example.Test.SmallPages`, routed only in the test build — see
  the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.SmallPages,
    list: [fields: [:code]],
    details: [fields: [:code]]
end
