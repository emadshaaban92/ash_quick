defmodule Example.Test.FieldRows.Domain do
  @moduledoc "Holds the resources behind a details page read field by field."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.FieldRows.City do
  @moduledoc "Where an `Example.Test.FieldRows.Owner` is, two hops from the page."
  use Ash.Resource,
    domain: Example.Test.FieldRows.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, create: [:name]]
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
  end
end

defmodule Example.Test.FieldRows.Owner do
  @moduledoc """
  Who an `Example.Test.FieldRows` belongs to, one hop from the page. Carries
  the extension because the page's create form offers a dropdown onto it.
  """
  use Ash.Resource,
    domain: Example.Test.FieldRows.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:name, :city_id]]

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
      label :name
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
    attribute :name, :string, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :city, Example.Test.FieldRows.City, public?: true
  end
end

defmodule Example.Test.FieldRows do
  @moduledoc """
  A record whose details page lists an attribute, a relationship path one and
  two hops deep, and a field drawn by a widget, and a page over it.

  In ETS rather than Postgres: nothing here is about what lands in a table.
  """
  use Ash.Resource,
    domain: Example.Test.FieldRows.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:code, :holder_name, :owner_id]]

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
      updated_at false
      updated_by false
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true
    attribute :holder_name, :string, public?: true
  end

  relationships do
    belongs_to :owner, Example.Test.FieldRows.Owner, public?: true
  end
end

defmodule Example.Test.FieldRowsLive.Quick do
  @moduledoc """
  The page over `Example.Test.FieldRows`, routed only in the test build — see
  the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.FieldRows,
    list: [fields: [:code]],
    details: [
      fields: [
        :holder_name,
        [owner: :name],
        [owner: [city: :name]],
        {:code, label: "Reference", widget: &__MODULE__.code_widget/1}
      ]
    ]

  def code_widget(assigns) do
    ~H"""
    <span class="font-mono">{@value}</span>
    """
  end
end
