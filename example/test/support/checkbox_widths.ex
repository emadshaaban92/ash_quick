defmodule Example.Test.CheckboxWidths.Domain do
  @moduledoc "Holds the resource whose forms put a checkbox between two fields."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.CheckboxWidths.Settings do
  @moduledoc "An embedded value with a boolean between two fields, drawn as a sub-form."
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :label, :string, public?: true
    attribute :enabled, :boolean, public?: true
    attribute :limit, :integer, public?: true
  end
end

defmodule Example.Test.CheckboxWidths do
  @moduledoc """
  A form with a boolean between two other fields, at the top level and in
  an embed's sub-form, so a test can read how wide each checkbox is drawn.

  In ETS rather than Postgres, like `Example.Test.TypedInputs`.
  """
  use Ash.Resource,
    domain: Example.Test.CheckboxWidths.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  @inputs [:code, :active, :note, :settings]

  actions do
    defaults [:read, create: @inputs, update: @inputs]

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

    labels do
      help :active, "Shown to readers."
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
    attribute :active, :boolean, public?: true
    attribute :note, :string, public?: true
    attribute :settings, Example.Test.CheckboxWidths.Settings, public?: true
  end
end

defmodule Example.Test.CheckboxWidthsLive.Quick do
  @moduledoc """
  The page over `Example.Test.CheckboxWidths`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.CheckboxWidths,
    list: [fields: [:code, :active, :note]],
    details: [fields: [:code, :active, :note]]
end
