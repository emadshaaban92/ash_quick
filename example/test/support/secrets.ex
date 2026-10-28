defmodule Example.Test.Secrets.Domain do
  @moduledoc "Holds the resource whose fields are sensitive."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.Secrets do
  @moduledoc """
  A record labelled by a `sensitive?` field, with a second one that is a date,
  and a page over it. Neither may reach a page, a title or a file, and the
  update form must neither show the stored value nor wipe it when left blank.

  In ETS rather than Postgres, like `Example.Test.DatedEntries`.
  """
  require Ash.Query

  use Ash.Resource,
    domain: Example.Test.Secrets.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:code, :pin, :issued_on]]

    update :update do
      primary? true
      accept [:code, :pin, :issued_on]
    end

    read :index do
      argument :search, :string

      prepare fn query, _context ->
        case Ash.Query.get_argument(query, :search) do
          blank when blank in [nil, ""] -> query
          search -> Ash.Query.filter(query, code == ^search)
        end
      end

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
      label :pin
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
    attribute :pin, :string, allow_nil?: false, public?: true, sensitive?: true
    attribute :issued_on, :date, public?: true, sensitive?: true
  end
end

defmodule Example.Test.SecretsLive.Quick do
  @moduledoc """
  The page over `Example.Test.Secrets`, routed only in the test build — see
  the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.Secrets,
    list: [fields: [:code, :pin, :issued_on]],
    details: [fields: [:code, :pin, :issued_on]]
end
