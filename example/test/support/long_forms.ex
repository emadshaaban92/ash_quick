defmodule Example.Test.LongForms.Domain do
  @moduledoc "Holds the resource whose big forms open as pages of their own."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.LongForms do
  @moduledoc """
  A resource declaring some of its actions `full_page`, and leaving others in
  the modal.

  `:create`, `:rework` (an update taking input) and `:destroy` (one taking
  none) open as pages; `:update` stays in the modal, so a test can tell the
  two apart on one resource.

  No authorizer: nothing here is about who may run what. In ETS rather than
  Postgres: nothing here is about what lands in a table.
  """
  use Ash.Resource,
    domain: Example.Test.LongForms.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:code, :note]
    end

    update :update do
      primary? true
      accept [:note]
    end

    update :rework do
      accept [:note]
    end

    read :index do
      argument :search, :string

      filter expr(is_nil(^arg(:search)) or contains(code, ^arg(:search)))

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

    forms do
      full_page [:create, :rework, :destroy]
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
    attribute :note, :string, public?: true
  end
end

defmodule Example.Test.LongFormsLive.Quick do
  @moduledoc """
  The page over `Example.Test.LongForms`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.LongForms,
    list: [fields: [:code, :note]],
    details: [fields: [:code, :note], featured_actions: [:update, :rework, :destroy]]
end
