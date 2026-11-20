defmodule Example.Test.CountedLabels.Domain do
  @moduledoc "Holds the bins labelled by a count that only a reader with a tenant can take."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.CountedLabels.Item do
  @moduledoc """
  An item in a bin, held per tenant with no `global?`: counting a bin's items
  needs a tenant, and a reader without one cannot ask.
  """
  use Ash.Resource,
    domain: Example.Test.CountedLabels.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, create: [:bin_id]]
  end

  multitenancy do
    strategy :attribute
    attribute :store_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :store_id, :uuid, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :bin, Example.Test.CountedLabels.Bin, public?: true
  end
end

defmodule Example.Test.CountedLabels.Sheet do
  @moduledoc "A page per bin, its code alone."
  @behaviour AshQuick.PrintTemplate

  @impl true
  def label, do: "Sheet"

  @impl true
  def load_opts, do: []

  @impl true
  def render(records) do
    "<html><body>" <> Enum.map_join(records, "\n", &"<h1>#{&1.code}</h1>") <> "</body></html>"
  end
end

defmodule Example.Test.CountedLabels.Bin do
  @moduledoc """
  A bin labelled by how many items the reader's store keeps in it — an
  aggregate over `Example.Test.CountedLabels.Item`, so a reader without a
  tenant gets no label, and every page naming a bin falls back to its id
  rather than failing the read. `:print` prints it, which names the PDF after
  the label.
  """
  use Ash.Resource,
    domain: Example.Test.CountedLabels.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:code]]

    read :index do
      argument :search, :string

      pagination do
        keyset? true
        offset? true
        default_limit 250
        countable :by_default
      end
    end

    update :print do
      accept []
      change {AshQuick.Print, template: Example.Test.CountedLabels.Sheet, delivery: :download}
    end
  end

  ash_quick do
    display do
      label :item_count
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
    has_many :items, Example.Test.CountedLabels.Item, public?: true
  end

  aggregates do
    count :item_count, :items, public?: true
  end
end

defmodule Example.Test.CountedLabels.Packing do
  @moduledoc "The join between a box and the spare bins it is packed with."
  use Ash.Resource,
    domain: Example.Test.CountedLabels.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy, create: [:box_id, :bin_id]]
  end

  relationships do
    belongs_to :box, Example.Test.CountedLabels.Box,
      primary_key?: true,
      allow_nil?: false,
      public?: true

    belongs_to :bin, Example.Test.CountedLabels.Bin,
      primary_key?: true,
      allow_nil?: false,
      public?: true
  end
end

defmodule Example.Test.CountedLabels.Box do
  @moduledoc """
  A box put in one bin, picked from a dropdown, and packed with spare bins,
  picked from a tag dropdown; a box can sit in a parent box. Its list and
  details draw the bin, by the relationship and by an explicit path to its
  label, and the details page the parent's bin, a path ending at a
  relationship: each loads a bin's label onto a record it names.
  """
  use Ash.Resource,
    domain: Example.Test.CountedLabels.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  alias Example.Test.CountedLabels.{Bin, Packing}

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:code, :bin_id, :parent_id]
      argument :spares, {:array, :uuid}
      change manage_relationship(:spares, :spare_bins, type: :append_and_remove)
    end

    update :update do
      primary? true
      accept [:code, :bin_id]
      require_atomic? false
      argument :spares, {:array, :uuid}
      change manage_relationship(:spares, :spare_bins, type: :append_and_remove)
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
  end

  relationships do
    belongs_to :bin, Bin, public?: true
    belongs_to :parent, __MODULE__, public?: true

    many_to_many :spare_bins, Bin do
      through Packing
      source_attribute_on_join_resource :box_id
      destination_attribute_on_join_resource :bin_id
      public? true
    end
  end
end

defmodule Example.Test.CountedBinsLive.Quick do
  @moduledoc """
  The page over `Example.Test.CountedLabels.Bin`, routed only in the test
  build — see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.CountedLabels.Bin,
    list: [fields: [:code]],
    details: [fields: [:code]]
end

defmodule Example.Test.CountedBoxesLive.Quick do
  @moduledoc """
  The page over `Example.Test.CountedLabels.Box`, routed only in the test
  build. Its list and details draw the bin a box is in, and its details the
  bin of the box it sits in.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.CountedLabels.Box,
    list: [fields: [:code, :bin, {[bin: :item_count], label: "Bin count"}]],
    details: [
      fields: [
        :code,
        :bin,
        {[bin: :item_count], label: "Bin count"},
        {[parent: :bin], label: "Parent bin"}
      ]
    ]
end
