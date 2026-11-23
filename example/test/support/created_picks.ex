defmodule Example.Test.CreatedPicks.Domain do
  @moduledoc "Holds the resource whose id list would create what it does not find."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.CreatedPicks.Tagging do
  @moduledoc "The join between `Example.Test.CreatedPicks` and its labels."
  use Ash.Resource,
    domain: Example.Test.CreatedPicks.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy, create: [:created_picks_id, :label_id]]
  end

  relationships do
    belongs_to :created_picks, Example.Test.CreatedPicks,
      primary_key?: true,
      allow_nil?: false,
      public?: true

    belongs_to :label, Example.Test.PickedLabels.Label,
      primary_key?: true,
      allow_nil?: false,
      public?: true
  end
end

defmodule Example.Test.CreatedPicks do
  @moduledoc """
  A record whose `:labels` are edited through `:picks`, a list of ids, by a
  `manage_relationship` change that creates what it finds no match for, and
  a page over it.

  A new label typed into the picker has no id to post, so the picker offers
  the labels there are and never an Add row, whatever the change says.
  """
  use Ash.Resource,
    domain: Example.Test.CreatedPicks.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  alias Example.Test.CreatedPicks.Tagging
  alias Example.Test.PickedLabels.Label

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:code]
      argument :picks, {:array, :uuid}

      change manage_relationship(:picks, :labels,
               type: :append_and_remove,
               on_no_match: :create
             )
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
      through Tagging
      source_attribute_on_join_resource :created_picks_id
      destination_attribute_on_join_resource :label_id
      public? true
    end
  end
end

defmodule Example.Test.CreatedPicksLive.Quick do
  @moduledoc """
  The page over `Example.Test.CreatedPicks`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.CreatedPicks,
    list: [fields: [:code]],
    details: [fields: [:code]]
end

defmodule Example.Test.SourcedLabels.Label do
  @moduledoc """
  What `Example.Test.SourcedLabels` is labelled with. Its create refuses a run
  stamped as a QuickView form's (`AshQuick.form_source/0`), which a
  `manage_relationship` never passes on to it.
  """
  use Ash.Resource,
    domain: Example.Test.CreatedPicks.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  actions do
    defaults [:read, create: [:name]]

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

  policies do
    policy action_type(:create) do
      forbid_if context_equals(:action_source, :ash_quick_form)
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if always()
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
end

defmodule Example.Test.SourcedLabels.Labelling do
  @moduledoc "The join between `Example.Test.SourcedLabels` and its labels."
  use Ash.Resource,
    domain: Example.Test.CreatedPicks.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy, create: [:sourced_labels_id, :label_id]]
  end

  relationships do
    belongs_to :sourced_labels, Example.Test.SourcedLabels,
      primary_key?: true,
      allow_nil?: false,
      public?: true

    belongs_to :label, Example.Test.SourcedLabels.Label,
      primary_key?: true,
      allow_nil?: false,
      public?: true
  end
end

defmodule Example.Test.SourcedLabels do
  @moduledoc """
  A record whose `:labels` are names its change creates when they match
  nothing, onto a label whose create policy reads `action_source`: the
  picker asks that create as it will run, with no `action_source`, so it
  offers the Add row the save goes on to honour.
  """
  use Ash.Resource,
    domain: Example.Test.CreatedPicks.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  alias Example.Test.SourcedLabels.{Label, Labelling}

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:code]
      argument :labels, {:array, :string}

      change manage_relationship(:labels,
               type: :append_and_remove,
               value_is_key: :name,
               on_no_match: :create
             )
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
      source_attribute_on_join_resource :sourced_labels_id
      destination_attribute_on_join_resource :label_id
      public? true
    end
  end
end

defmodule Example.Test.SourcedLabelsLive.Quick do
  @moduledoc """
  The page over `Example.Test.SourcedLabels`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.SourcedLabels,
    list: [fields: [:code]],
    details: [fields: [:code]]
end
