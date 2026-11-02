defmodule Example.Test.StampedTemplates.Domain do
  @moduledoc "Holds the resource whose forms are drawn by custom templates."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.StampedTemplates do
  @moduledoc """
  A timestamp whose two update forms are custom templates beside the page
  below: `:update` draws it with AshQuick's `.input`, and `:restamp` with this
  app's own `ExampleWeb.CoreComponents.input/1` and
  `AshQuick.Timezone.input_value/1`, as a template must.

  In its own directory, because a QuickView embeds every `action_*` template
  beside its module.
  """
  use Ash.Resource,
    domain: Example.Test.StampedTemplates.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:code, :stamped_at], update: [:stamped_at]]

    update :restamp do
      accept [:stamped_at]
    end

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
    attribute :stamped_at, :utc_datetime_usec, public?: true
  end
end

defmodule Example.Test.StampedTemplatesLive.Quick do
  @moduledoc """
  The page over `Example.Test.StampedTemplates`, routed only in the test build
  — see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.StampedTemplates,
    list: [fields: [:code, :stamped_at]],
    details: [fields: [:code, :stamped_at]]
end
