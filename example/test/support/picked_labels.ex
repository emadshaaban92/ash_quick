defmodule Example.Test.PickedLabels.Domain do
  @moduledoc "Holds the resource whose labels are picked through an argument named for nothing."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.PickedLabels.Label do
  @moduledoc "What `Example.Test.PickedLabels` is labelled with."
  use Ash.Resource,
    domain: Example.Test.PickedLabels.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:name, :shelf]]

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
      # A calculation, so the dropdown has to load it rather than find it
      # selected along with the label. Blank for a label with no shelf.
      hint :place
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
    attribute :shelf, :string, public?: true
  end

  calculations do
    calculate :place,
              :string,
              expr(if is_nil(shelf), do: "", else: "Shelf " <> shelf),
              public?: true
  end
end

defmodule Example.Test.PickedLabels.Labelling do
  @moduledoc "The join between `Example.Test.PickedLabels` and its labels."
  use Ash.Resource,
    domain: Example.Test.PickedLabels.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy, create: [:picked_labels_id, :label_id]]
  end

  relationships do
    belongs_to :picked_labels, Example.Test.PickedLabels,
      primary_key?: true,
      allow_nil?: false,
      public?: true

    belongs_to :label, Example.Test.PickedLabels.Label,
      primary_key?: true,
      allow_nil?: false,
      public?: true
  end
end

defmodule Example.Test.PickedLabels do
  @moduledoc """
  A record whose `:labels` are edited through an argument called `:picks`,
  which only its `manage_relationship` change ties to them, and a page over
  it.

  In ETS rather than Postgres: nothing here is about what lands in a table.
  """
  use Ash.Resource,
    domain: Example.Test.PickedLabels.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  alias Example.Test.PickedLabels.{Label, Labelling}

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:code]
      argument :picks, {:array, :uuid}
      change manage_relationship(:picks, :labels, type: :append_and_remove)
    end

    update :update do
      primary? true
      accept [:code]
      require_atomic? false
      argument :picks, {:array, :uuid}
      change manage_relationship(:picks, :labels, type: :append_and_remove)
    end

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
  end

  relationships do
    many_to_many :labels, Label do
      through Labelling
      source_attribute_on_join_resource :picked_labels_id
      destination_attribute_on_join_resource :label_id
      public? true
    end
  end
end

defmodule Example.Test.PickedLabelsLive.Quick do
  @moduledoc """
  The page over `Example.Test.PickedLabels`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.PickedLabels,
    list: [fields: [:code]],
    details: [fields: [:code]]
end
