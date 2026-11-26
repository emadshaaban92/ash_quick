defmodule Example.Test.ManagedRows.Domain do
  @moduledoc "Holds the resource whose update manages its stored rows."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.ManagedRows.Item do
  @moduledoc """
  One stored row of `Example.Test.ManagedRows`. `:secret` is hidden from every
  reader by a field policy, so an update sub-form over a stored row must leave
  it out, and the save must keep it.
  """
  use Ash.Resource,
    domain: Example.Test.ManagedRows.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  field_policies do
    field_policy :secret do
      forbid_if always()
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:status, :note, :secret]
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:status, :note, :secret]
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :status, :string, allow_nil?: true, public?: true
    attribute :note, :string, allow_nil?: true, public?: true
    attribute :secret, :string, allow_nil?: true, public?: true
  end

  relationships do
    belongs_to :managed_rows, Example.Test.ManagedRows, public?: true
  end
end

defmodule Example.Test.ManagedRows do
  @moduledoc """
  An update that manages its `has_many` rows with `direct_control`: every row
  the save posts is kept or updated, and every stored row it leaves out is
  destroyed. So the update form must draw one sub-form per stored row, or a
  plain save would destroy them all.

  In ETS rather than Postgres, like `Example.Test.NestedItems`.
  """
  use Ash.Resource,
    domain: Example.Test.ManagedRows.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:code]
      argument :items, {:array, :map}, allow_nil?: true, default: []
      change manage_relationship(:items, type: :create)
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:code]
      argument :items, {:array, :map}, allow_nil?: true
      change manage_relationship(:items, type: :direct_control)
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
    has_many :items, Example.Test.ManagedRows.Item, public?: true, sort: [status: :asc]
  end
end

defmodule Example.Test.ManagedRowsLive.Quick do
  @moduledoc """
  The page over `Example.Test.ManagedRows`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.ManagedRows,
    list: [fields: [:code]],
    details: [fields: [:code]]
end

defmodule Example.Test.ManagedRowsHeldLive.Quick do
  @moduledoc """
  `Example.Test.ManagedRowsLive.Quick` with each row's `:note` disabled by the
  page's `adjust_form/2`, so a save must leave every stored note as it is.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.ManagedRows,
    list: [fields: [:code]],
    details: [fields: [:code]]

  alias AshQuick.FormState

  defp adjust_form(%{action: %{name: action}} = state, _options)
       when action in [:create, :update] do
    FormState.update_each(state, [:items], &FormState.disable(&1, :note, true))
  end

  defp adjust_form(state, _options), do: state
end

defmodule Example.Test.ManagedRowsNarrowLive.Quick do
  @moduledoc """
  `Example.Test.ManagedRowsLive.Quick` with a top-level `load:` that narrows
  the rows to `:status`, which the update form's own load must widen again.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.ManagedRows,
    load: [items: [:status]],
    list: [fields: [:code]],
    details: [fields: [:code]]
end

defmodule Example.Test.ManagedRows.Part do
  @moduledoc """
  A part of a `Example.Test.ManagedRows.Row`, two levels under the nest. Its
  update manages the row it belongs to, back up the chain, so walking the
  managed relationships comes round to `:parts` again.
  """
  use Ash.Resource,
    domain: Example.Test.ManagedRows.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:label]
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:label]
      argument :row, :map, allow_nil?: true
      change manage_relationship(:row, type: :direct_control)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :label, :string, allow_nil?: true, public?: true
  end

  relationships do
    belongs_to :row, Example.Test.ManagedRows.Row, public?: true
  end
end

defmodule Example.Test.ManagedRows.Row do
  @moduledoc "A row of `Example.Test.ManagedNest`, whose update manages its own parts."
  use Ash.Resource,
    domain: Example.Test.ManagedRows.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:status]
      argument :parts, {:array, :map}, allow_nil?: true, default: []
      change manage_relationship(:parts, type: :create)
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:status]
      argument :parts, {:array, :map}, allow_nil?: true
      change manage_relationship(:parts, type: :direct_control)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :status, :string, allow_nil?: true, public?: true
  end

  relationships do
    belongs_to :managed_nest, Example.Test.ManagedNest, public?: true
    has_many :parts, Example.Test.ManagedRows.Part, public?: true, sort: [label: :asc]
  end
end

defmodule Example.Test.ManagedRows.Tag do
  @moduledoc "A tag a `Example.Test.ManagedNest` holds through a weighted join."
  use Ash.Resource,
    domain: Example.Test.ManagedRows.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy, create: [:name], update: [:name]]
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: true, public?: true
  end
end

defmodule Example.Test.ManagedRows.Tagging do
  @moduledoc "The join between a nest and a tag, carrying a `weight`."
  use Ash.Resource,
    domain: Example.Test.ManagedRows.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy, create: [:weight], update: [:weight]]
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :weight, :integer, allow_nil?: true, public?: true
  end

  relationships do
    belongs_to :managed_nest, Example.Test.ManagedNest, public?: true
    belongs_to :tag, Example.Test.ManagedRows.Tag, public?: true
  end
end

defmodule Example.Test.ManagedNest do
  @moduledoc """
  An update that manages, with `direct_control`, rows that manage their own
  parts (whose update manages the row back), and a `many_to_many` of tags
  whose join carries a `weight`. Its update form must draw every stored row,
  part and tag, and a plain save must keep them all, joins included.
  """
  use Ash.Resource,
    domain: Example.Test.ManagedRows.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:code]
      argument :rows, {:array, :map}, allow_nil?: true, default: []
      change manage_relationship(:rows, type: :create)
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:code]
      argument :rows, {:array, :map}, allow_nil?: true
      argument :tags, {:array, :map}, allow_nil?: true
      change manage_relationship(:rows, type: :direct_control)
      change manage_relationship(:tags, type: :direct_control, join_keys: [:weight])
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
    has_many :rows, Example.Test.ManagedRows.Row, public?: true, sort: [status: :asc]

    many_to_many :tags, Example.Test.ManagedRows.Tag,
      through: Example.Test.ManagedRows.Tagging,
      source_attribute_on_join_resource: :managed_nest_id,
      destination_attribute_on_join_resource: :tag_id,
      public?: true,
      sort: [name: :asc]
  end
end

defmodule Example.Test.ManagedNestLive.Quick do
  @moduledoc """
  The page over `Example.Test.ManagedNest`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.ManagedNest,
    list: [fields: [:code]],
    details: [fields: [:code]]
end

defmodule Example.Test.KeyedRows.Member do
  @moduledoc """
  A member of `Example.Test.KeyedRows`, keyed by `(team, seat)`. A new row
  draws `:team` and takes its `:seat` from a default, so it posts one of its
  key fields and not the other.
  """
  use Ash.Resource,
    domain: Example.Test.ManagedRows.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:team, :note]
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:note]
    end
  end

  attributes do
    attribute :team, :string, primary_key?: true, allow_nil?: false, public?: true

    attribute :seat, :string,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      writable?: false,
      default: &Ash.UUIDv7.generate/0

    attribute :note, :string, allow_nil?: true, public?: true
  end

  relationships do
    belongs_to :keyed_rows, Example.Test.KeyedRows, public?: true
  end
end

defmodule Example.Test.KeyedRows do
  @moduledoc """
  An update managing `has_many` rows whose primary key is composite, one of
  its fields drawn on a new row. In ETS, like `Example.Test.ManagedRows`.
  """
  use Ash.Resource,
    domain: Example.Test.ManagedRows.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:code]
      argument :members, {:array, :map}, allow_nil?: true, default: []
      change manage_relationship(:members, type: :create)
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:code]
      argument :members, {:array, :map}, allow_nil?: true
      change manage_relationship(:members, type: :direct_control)
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
    has_many :members, Example.Test.KeyedRows.Member, public?: true, sort: [team: :asc]
  end
end

defmodule Example.Test.KeyedRowsLive.Quick do
  @moduledoc """
  The page over `Example.Test.KeyedRows`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.KeyedRows,
    list: [fields: [:code]],
    details: [fields: [:code]]
end

defmodule Example.Test.ManagedRowsLockedLive.Quick do
  @moduledoc """
  `Example.Test.ManagedRowsLive.Quick` with the whole `:items` list disabled
  on the update by the page's `adjust_form/2`, so a save must leave every
  stored row as it is.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.ManagedRows,
    list: [fields: [:code]],
    details: [fields: [:code]]

  alias AshQuick.FormState

  defp adjust_form(%{action: %{name: :update}} = state, _options),
    do: FormState.disable(state, :items, true)

  defp adjust_form(state, _options), do: state
end

defmodule Example.Test.ManagedRowsHiddenLive.Quick do
  @moduledoc """
  `Example.Test.ManagedRowsLive.Quick` with the whole `:items` list hidden on
  the update by the page's `adjust_form/2`, so a save must leave every stored
  row as it is.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.ManagedRows,
    list: [fields: [:code]],
    details: [fields: [:code]]

  alias AshQuick.FormState

  defp adjust_form(%{action: %{name: :update}} = state, _options),
    do: FormState.hide(state, :items, true)

  defp adjust_form(state, _options), do: state
end
