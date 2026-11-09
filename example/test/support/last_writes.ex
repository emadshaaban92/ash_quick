defmodule Example.Test.LastWrites.Domain do
  @moduledoc "Holds the resources whose bookkeeping declares only some fields."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.LastWrites do
  @moduledoc """
  A resource that declares only the `updated_*` half of its bookkeeping, and a
  page over it.

  Every resource in this application that records a last write records the
  creation too, so a details header holding only the updated half is built
  here.

  In ETS rather than Postgres, like `Example.Test.DefaultPages`. The table is
  shared, so only `ExampleWeb.DetailsScenarioTest` writes to it.
  """
  use Ash.Resource,
    domain: Example.Test.LastWrites.Domain,
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
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true
  end
end

defmodule Example.Test.LastWritesLive.Quick do
  @moduledoc """
  The page over `Example.Test.LastWrites`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.LastWrites,
    list: [fields: [:code]],
    details: [fields: [:code]]
end

defmodule Example.Test.WritersOnly do
  @moduledoc """
  A resource that declares who created and who last wrote it but no
  timestamps, and a page over it.

  With no timestamps, nothing shows a last write is the creation, so a header
  naming the same writer twice keeps both halves; every other resource in this
  application that names its writers also records when.

  In ETS, beside `Example.Test.LastWrites`. The table is shared, so only
  `ExampleWeb.DetailsScenarioTest` writes to it.
  """
  use Ash.Resource,
    domain: Example.Test.LastWrites.Domain,
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
      updated_at false
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true
  end
end

defmodule Example.Test.WritersOnlyLive.Quick do
  @moduledoc """
  The page over `Example.Test.WritersOnly`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.WritersOnly,
    list: [fields: [:code]],
    details: [fields: [:code]]
end
