defmodule Example.Test.DigitsOnly.Domain do
  @moduledoc "Holds the resource whose only job is to refuse a value through `match/2`."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.DigitsOnly do
  @moduledoc """
  A resource with `validate match/2` on two fields, and a page over it.

  Every error `match/2` raises carries the `%Regex{}` it tested against, whether
  or not the message names it — and a Regex has no `String.Chars`. No resource
  in this application validates by pattern, so the case is built here, where a
  page can refuse a value through it and a test can watch the page survive.

  In ETS rather than Postgres: nothing here is about what lands in a table, and
  no migration should exist for a resource no user of the application sees.
  """
  require Ash.Query

  use Ash.Resource,
    domain: Example.Test.DigitsOnly.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    default_accept [:code, :name, :ref]
    defaults [:read, :create]

    read :index do
      argument :search, :string

      prepare fn query, _context ->
        case Ash.Query.get_argument(query, :search) do
          blank when blank in [nil, ""] -> query
          search -> Ash.Query.filter(query, contains(code, ^search))
        end
      end

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

  validations do
    validate match(:code, ~r/^\d+$/), message: "must be digits"

    # The same var, named this time.
    validate match(:ref, ~r/^[A-Z]+$/), message: "must match %{match}"
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :code, :string, allow_nil?: false, public?: true

    # Required, so one submit can be refused twice: two errors take the form's
    # own error path rather than the single-attribute one.
    attribute :name, :string, allow_nil?: false, public?: true

    attribute :ref, :string, public?: true
  end
end

defmodule Example.Test.DigitsOnlyLive.Quick do
  @moduledoc """
  The page over `Example.Test.DigitsOnly`, routed only in the test build — see
  the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.DigitsOnly,
    list: [fields: [:code, :name]],
    details: [fields: [:code, :name]]
end
