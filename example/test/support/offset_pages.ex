defmodule Example.Test.OffsetPages.Domain do
  @moduledoc "Holds the resource whose list action pages by offset alone."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.OffsetPages do
  @moduledoc """
  A resource whose list action pages by offset and not by keyset, and a page
  over it.

  Every list in this application allows both, which hides a list that reads
  only offsets: it pages fine, since a QuickView pages by offset, and its
  export is the read that has to cope without a keyset. Its pages hold at
  most two rows, so an export of a handful of rows reads several batches.

  In ETS rather than Postgres, like `Example.Test.SmallPages`. The table is
  shared, so only `ExampleWeb.OffsetExportTest` writes to it.
  """
  use Ash.Resource,
    domain: Example.Test.OffsetPages.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:code]]

    read :index do
      argument :search, :string

      prepare build(sort: [code: :asc])

      pagination do
        keyset? false
        offset? true
        default_limit 2
        max_page_size 2
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

defmodule Example.Test.OffsetPagesLive.Quick do
  @moduledoc """
  The page over `Example.Test.OffsetPages`, routed only in the test build — see
  the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.OffsetPages,
    list: [fields: [:code]],
    details: [fields: [:code]]
end

defmodule Example.Test.WideOffsetPages do
  @moduledoc """
  `Example.Test.OffsetPages` with Ash's own `max_page_size` of 250 over its
  pages of two, and a page over it.

  `ExampleWeb.OffsetExportTest` counts the reads an export of it makes: one
  batch of up to 250 rows, not one for each page of two. The table is shared,
  so only that module writes to it.
  """
  use Ash.Resource,
    domain: Example.Test.OffsetPages.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:code]]

    read :index do
      argument :search, :string

      prepare build(sort: [code: :asc])

      pagination do
        keyset? false
        offset? true
        default_limit 2
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

defmodule Example.Test.WideOffsetPagesLive.Quick do
  @moduledoc """
  The page over `Example.Test.WideOffsetPages`, routed only in the test build
  — see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.WideOffsetPages,
    list: [fields: [:code]],
    details: [fields: [:code]]
end
