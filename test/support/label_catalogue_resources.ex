defmodule AshQuick.Test.LabelCatalogue.Domain do
  @moduledoc "Holds the resources the label catalogue reads. Nothing here is run."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshQuick.Test.LabelCatalogue.Shelf do
  @moduledoc """
  A resource no QuickView serves, reached only through a crate's column.

  Its `:state` is the point: a list showing `[shelf: :state]` draws the
  shelf's values, so they are labels of the crate's page.
  """
  use Ash.Resource,
    domain: AshQuick.Test.LabelCatalogue.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :state, :atom, public?: true, constraints: [one_of: [:empty, :full]]
  end

  actions do
    defaults [:read]
  end
end

defmodule AshQuick.Test.LabelCatalogue.Crate do
  @moduledoc "The resource behind the fixture QuickView."
  use Ash.Resource,
    domain: AshQuick.Test.LabelCatalogue.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :code, :string, public?: true
  end

  relationships do
    belongs_to :shelf, AshQuick.Test.LabelCatalogue.Shelf, public?: true
  end

  actions do
    default_accept [:code]
    defaults [:read, :create, :update, :destroy]

    update :seal do
      argument :seal_colour, :atom, constraints: [one_of: [:red, :blue]]
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

    liveness do
      enabled? false
    end

    versioning do
      enabled? false
    end

    bookkeeping do
      inserted_at false
      updated_at false
      inserted_by false
      updated_by false
    end
  end
end

defmodule AshQuick.Test.LabelCatalogue.CrateLive.Quick do
  @moduledoc "A QuickView stating a label of every kind the catalogue reads."
  use AshQuick.LiveView.QuickView,
    resource: AshQuick.Test.LabelCatalogue.Crate,
    filters: [%{"name" => "sealed", "label" => "Sealed ones", "expression" => %{}}],
    list: [
      fields: [:code, {[shelf: :state], label: "Shelf State"}],
      new_action_label: "Pack a Crate",
      bulk_actions: [:seal, %{title: "Weigh them", func: %Phoenix.LiveView.JS{}}]
    ]
end

defmodule AshQuick.Test.LabelCatalogue.Router do
  @moduledoc "Serves the one fixture QuickView."
  use Phoenix.Router

  import AshQuick.LiveView.Router

  quick_view("/crates", AshQuick.Test.LabelCatalogue.CrateLive.Quick)
end

defmodule AshQuick.Test.LabelCatalogue.Nav do
  @moduledoc "A nav with a label of its own and a group."
  use AshQuick.Nav, router: AshQuick.Test.LabelCatalogue.Router

  nav do
    entry("/crates", label: "Crate Store")
    group("Warehouse", ~w(/crates))
  end
end
