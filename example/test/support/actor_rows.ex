defmodule Example.Test.ActorRows.Domain do
  @moduledoc "Holds the resource whose actions manage rows that need an actor."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.ActorRows.NeedsActor do
  @moduledoc """
  Refuses a changeset built without an actor, and stamps the actor's id on
  `:made_by` otherwise. A nested sub-form's changeset runs it as the form
  validates, so a sub-form built without the page's actor shows the error and
  the save is refused.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, %{actor: %{id: id}}),
    do: Ash.Changeset.force_change_attribute(changeset, :made_by, id)

  def change(changeset, _opts, _context),
    do: Ash.Changeset.add_error(changeset, field: :note, message: "needs an actor")
end

defmodule Example.Test.ActorRows.Line do
  @moduledoc "A `has_many` row of `Example.Test.ActorRows`, written only by an actor."
  use Ash.Resource,
    domain: Example.Test.ActorRows.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:note]
      change Example.Test.ActorRows.NeedsActor
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:note]
      change Example.Test.ActorRows.NeedsActor
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :note, :string, allow_nil?: true, public?: true
    attribute :made_by, :uuid, allow_nil?: true, public?: true, writable?: false
  end

  relationships do
    belongs_to :actor_rows, Example.Test.ActorRows, public?: true
  end
end

defmodule Example.Test.ActorRows.Keeper do
  @moduledoc "The `has_one` row of `Example.Test.ActorRows`, written only by an actor."
  use Ash.Resource,
    domain: Example.Test.ActorRows.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:note]
      change Example.Test.ActorRows.NeedsActor
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:note]
      change Example.Test.ActorRows.NeedsActor
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :note, :string, allow_nil?: true, public?: true
    attribute :made_by, :uuid, allow_nil?: true, public?: true, writable?: false
  end

  relationships do
    belongs_to :actor_rows, Example.Test.ActorRows, public?: true
  end
end

defmodule Example.Test.ActorRows do
  @moduledoc """
  Create and update manage a `has_many` list and a `has_one` row whose
  actions need an actor: their policies authorize only an actor, and a change
  refuses a changeset without one. So each sub-form must be built with the
  page's actor, which AshPhoenix takes from the form's scope.

  In ETS, like `Example.Test.ManagedRows`.
  """
  use Ash.Resource,
    domain: Example.Test.ActorRows.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:code]
      argument :lines, {:array, :map}, allow_nil?: true, default: []
      argument :keeper, :map, allow_nil?: true
      change manage_relationship(:lines, type: :create)
      change manage_relationship(:keeper, type: :create)
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:code]
      argument :lines, {:array, :map}, allow_nil?: true
      argument :keeper, :map, allow_nil?: true
      change manage_relationship(:lines, type: :direct_control)
      change manage_relationship(:keeper, type: :direct_control)
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
    has_many :lines, Example.Test.ActorRows.Line, public?: true, sort: [note: :asc]
    has_one :keeper, Example.Test.ActorRows.Keeper, public?: true
  end
end

defmodule Example.Test.ActorRowsLive.Quick do
  @moduledoc """
  The page over `Example.Test.ActorRows`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.ActorRows,
    list: [fields: [:code]],
    details: [fields: [:code]]
end
