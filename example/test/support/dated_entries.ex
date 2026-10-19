defmodule Example.Test.DatedEntries.Domain do
  @moduledoc "Holds the resource whose fields are dates and times of each kind."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.DatedEntries do
  @moduledoc """
  A field of each date and time type, and a page over them: a date, a time,
  a naive datetime and a UTC datetime with microseconds. The list and the
  details page show each the way `AshQuick.Config` formats it.

  In ETS rather than Postgres, like `Example.Test.EnumPicks`.
  """
  use Ash.Resource,
    domain: Example.Test.DatedEntries.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:code, :due_on, :opens_at, :logged_at, :stamped_at]]

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
    attribute :due_on, :date, public?: true
    attribute :opens_at, :time, public?: true
    attribute :logged_at, :naive_datetime, public?: true
    attribute :stamped_at, :utc_datetime_usec, public?: true
  end
end

defmodule Example.Test.DatedEntriesLive.Quick do
  @moduledoc """
  The page over `Example.Test.DatedEntries`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.DatedEntries,
    list: [fields: [:code, :due_on, :opens_at, :logged_at, :stamped_at]],
    details: [fields: [:code, :due_on, :opens_at, :logged_at, :stamped_at]]
end
