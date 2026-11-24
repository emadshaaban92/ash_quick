defmodule Example.Test.PickedPlaces.Domain do
  @moduledoc "Holds the trips whose pickers follow what is picked beside them."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.PickedPlaces.QuickDefaults do
  @moduledoc false
  # The `ash_quick` block every resource here shares: a label, nothing stamped
  # or versioned.
  defmacro __using__(label: label) do
    quote do
      ash_quick do
        display do
          label unquote(label)
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
    end
  end
end

defmodule Example.Test.PickedPlaces.Country do
  @moduledoc "Where a trip goes."
  use Ash.Resource,
    domain: Example.Test.PickedPlaces.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  use Example.Test.PickedPlaces.QuickDefaults, label: :name

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

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
  end
end

defmodule Example.Test.PickedPlaces.City do
  @moduledoc """
  A city of a country. Its lookup action takes the country as an argument,
  for `AshQuick.FormState.lookup_args/3`; with none, it reads every city.
  It reads two cities a page at most, so a save holding more reads them in
  pages. A city can be deactivated.
  """
  use Ash.Resource,
    domain: Example.Test.PickedPlaces.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:name, :country_id, :port?]]

    read :index do
      argument :search, :string
      argument :country_id, :uuid

      filter expr(is_nil(^arg(:country_id)) or country_id == ^arg(:country_id))

      pagination do
        keyset? true
        offset? true
        default_limit 2
        max_page_size 2
        countable :by_default
      end
    end
  end

  ash_quick do
    display do
      label :name
    end

    activation do
      enabled? true
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
    attribute :port?, :boolean, default: false, public?: true
  end

  relationships do
    belongs_to :country, Example.Test.PickedPlaces.Country, public?: true
  end
end

defmodule Example.Test.PickedPlaces.Stop do
  @moduledoc "The join between a trip and the cities it stops in."
  use Ash.Resource,
    domain: Example.Test.PickedPlaces.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy, create: [:trip_id, :city_id]]
  end

  relationships do
    belongs_to :trip, Example.Test.PickedPlaces, primary_key?: true, allow_nil?: false
    belongs_to :city, Example.Test.PickedPlaces.City, primary_key?: true, allow_nil?: false
  end
end

defmodule Example.Test.PickedPlaces.Label do
  @moduledoc """
  What a trip is labelled with: typed into a picker that creates a name no
  label holds. Its lookup action hides archived labels itself, and the
  trip's hook leaves out restricted ones.
  """
  use Ash.Resource,
    domain: Example.Test.PickedPlaces.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  use Example.Test.PickedPlaces.QuickDefaults, label: :name

  actions do
    defaults [:read, create: [:name, :archived?, :restricted?]]

    read :index do
      argument :search, :string
      filter expr(archived? == false)

      pagination do
        keyset? true
        offset? true
        default_limit 250
        countable :by_default
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :ci_string, allow_nil?: false, public?: true
    attribute :archived?, :boolean, default: false, public?: true
    attribute :restricted?, :boolean, default: false, public?: true
  end

  identities do
    identity :unique_name, [:name], pre_check_with: Example.Test.PickedPlaces.Domain
  end
end

defmodule Example.Test.PickedPlaces.Labelling do
  @moduledoc "The join between a trip and its labels."
  use Ash.Resource,
    domain: Example.Test.PickedPlaces.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy, create: [:trip_id, :label_id]]
  end

  relationships do
    belongs_to :trip, Example.Test.PickedPlaces, primary_key?: true, allow_nil?: false
    belongs_to :label, Example.Test.PickedPlaces.Label, primary_key?: true, allow_nil?: false
  end
end

defmodule Example.Test.PickedPlaces.Owner do
  @moduledoc """
  Who a trip belongs to: a resource with no lookup action, no read taking a
  search. The trip's page draws its `belongs_to` with a widget.
  """
  use Ash.Resource,
    domain: Example.Test.PickedPlaces.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  use Example.Test.PickedPlaces.QuickDefaults, label: :name

  actions do
    defaults [:read, create: [:name]]
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
  end
end

defmodule Example.Test.PickedPlaces.Leg do
  @moduledoc "One leg of a trip: a sub-form of its own on the trip's form."
  use Ash.Resource, data_layer: :embedded

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    attribute :mode, :atom,
      public?: true,
      constraints: [one_of: [:bus, :train, :ship, :plane]]
  end
end

defmodule Example.Test.PickedPlaces do
  @moduledoc """
  A trip whose pickers follow what is picked beside them, and the page over
  it, routed only in the test build. `Example.Test.PickedPlacesLive.Quick`'s
  `adjust_form/2` says how:

    * `:city` offers only the cities of the picked country, through the
      lookup action's `country_id` argument (`lookup_args/3`);
    * `:stop_ids`, a list over a many-to-many, offers only the cities of the
      picked country too, through a filter (`filter/3`);
    * `:status` offers only draft and submitted (`options/3`);
    * each leg of a cruise offers only the ship (`options/3` on a sub-form);
    * `:labels`, typed names that create a label none holds, leaves out
      restricted labels (`filter/3`); its lookup action hides archived ones.

  `:port` is a `belongs_to` whose relationship filters to ports, and that
  the hook leaves alone: the save holds it to that filter all the same.
  `:owner` is a `belongs_to` onto a resource with no lookup action, drawn
  by a widget, which the save leaves to the widget.

  In ETS rather than Postgres: nothing here is about what lands in a table.
  The table is shared by every test, so each one finds its rows by the codes
  it made.
  """
  use Ash.Resource,
    domain: Example.Test.PickedPlaces.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  use Example.Test.PickedPlaces.QuickDefaults, label: :code

  resource do
    plural_name :picked_places
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:code, :kind, :status, :country_id, :city_id, :port_id, :owner_id, :legs]
      argument :stop_ids, {:array, :uuid}
      change manage_relationship(:stop_ids, :stops, type: :append_and_remove)
      argument :labels, {:array, :ci_string}

      change manage_relationship(:labels,
               type: :append_and_remove,
               value_is_key: :name,
               on_no_match: :create
             )
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:code, :kind, :status, :country_id, :city_id, :port_id, :owner_id, :legs]
      argument :stop_ids, {:array, :uuid}
      change manage_relationship(:stop_ids, :stops, type: :append_and_remove)
      argument :labels, {:array, :ci_string}

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

  attributes do
    uuid_v7_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true

    attribute :kind, :atom,
      allow_nil?: false,
      default: :tour,
      public?: true,
      constraints: [one_of: [:tour, :cruise]]

    attribute :status, :atom,
      public?: true,
      constraints: [one_of: [:draft, :submitted, :approved]]

    attribute :legs, {:array, Example.Test.PickedPlaces.Leg}, public?: true, default: []
  end

  relationships do
    belongs_to :country, Example.Test.PickedPlaces.Country, public?: true
    belongs_to :city, Example.Test.PickedPlaces.City, public?: true
    belongs_to :owner, Example.Test.PickedPlaces.Owner, public?: true

    belongs_to :port, Example.Test.PickedPlaces.City do
      public? true
      filter expr(port? == true)
    end

    many_to_many :stops, Example.Test.PickedPlaces.City do
      through Example.Test.PickedPlaces.Stop
      source_attribute_on_join_resource :trip_id
      destination_attribute_on_join_resource :city_id
      public? true
    end

    many_to_many :labels, Example.Test.PickedPlaces.Label do
      through Example.Test.PickedPlaces.Labelling
      source_attribute_on_join_resource :trip_id
      destination_attribute_on_join_resource :label_id
      public? true
    end
  end
end

defmodule Example.Test.PickedPlacesLive.Quick do
  @moduledoc """
  The page over `Example.Test.PickedPlaces`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.PickedPlaces,
    list: [fields: [:code, :kind, :status]],
    details: [fields: [:code, :kind, :status]],
    form: [widgets: %{owner: &__MODULE__.owner_input/1}]

  import Ash.Expr

  @doc "The owner's widget: a plain text box for its id."
  def owner_input(assigns) do
    ~H"""
    <input
      type="text"
      name="form[owner_id]"
      value={@phx_field.form[:owner_id].value}
      data-owner-widget
    />
    """
  end

  alias AshQuick.FormState

  defp adjust_form(%{action: %{name: action}} = state, _options)
       when action in [:create, :update] do
    country = FormState.value(state, :country)

    state
    |> FormState.lookup_args(:city, %{country_id: country})
    |> then(
      &if country, do: FormState.filter(&1, :stop_ids, expr(country_id == ^country)), else: &1
    )
    |> FormState.options(:status, [:draft, :submitted])
    |> FormState.filter(:labels, expr(restricted? == false))
    |> FormState.update_each([:legs], fn leg ->
      if FormState.value(leg.parent, :kind) == :cruise,
        do: FormState.options(leg, :mode, [:ship]),
        else: leg
    end)
  end

  defp adjust_form(state, _options), do: state
end
