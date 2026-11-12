defmodule Example.Test.UncountedPages.Domain do
  @moduledoc "Holds the resource whose list actions do not count by default."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.UncountedPages do
  @moduledoc """
  A resource whose default list cannot be counted, a second list that counts
  only when asked, and a page over it.

  A lookup action has to paginate with a default limit, but nothing asks it to
  count by default: Ash's `countable` defaults to `true`, which counts only a
  read that asks, and `false` refuses to count at all. A page read without
  asking comes back with `count: nil`. Every other list in this application
  says `countable :by_default`, so the case is built here.

  In ETS rather than Postgres, like `Example.Test.DefaultPages`. The table is
  shared, so only `ExampleWeb.UncountedPagesTest` writes to it.
  """
  use Ash.Resource,
    domain: Example.Test.UncountedPages.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:code]]

    read :index do
      argument :search, :string

      prepare build(sort: [code: :asc])

      pagination do
        offset? true
        default_limit 2
        max_page_size 10
        countable false
      end
    end

    # Ash's default, `countable true`.
    read :counted_on_request do
      argument :search, :string

      prepare build(sort: [code: :asc])

      pagination do
        offset? true
        default_limit 2
        max_page_size 10
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

defmodule Example.Test.UncountedPagesLive.Quick do
  @moduledoc """
  The page over `Example.Test.UncountedPages`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.UncountedPages,
    list: [fields: [:code]],
    details: [fields: [:code]]
end
