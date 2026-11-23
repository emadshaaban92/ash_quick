defmodule Example.Test.ShapedBundles.Domain do
  @moduledoc "Holds the resource whose sub-forms follow what is typed into them."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.ShapedBundles.Part do
  @moduledoc "A part of a device item: a sub-form inside an item's sub-form."
  use Ash.Resource, data_layer: :embedded

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    attribute :name, :string, public?: true
  end
end

defmodule Example.Test.ShapedBundles.Spec do
  @moduledoc "A device item's spec: a single sub-form inside an item's sub-form."
  use Ash.Resource, data_layer: :embedded

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    attribute :watts, :integer, public?: true
  end
end

defmodule Example.Test.ShapedBundles.Item do
  @moduledoc "One item of a bundle: a row of sub-forms on the bundle's form."
  use Ash.Resource, data_layer: :embedded

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  # A device has no hours: a stored service turned device keeps the hours it
  # hides, which this refuses with an error the form has no input to show.
  validations do
    validate absent(:hours), where: [attribute_equals(:kind, :device)]
  end

  attributes do
    attribute :kind, :atom,
      allow_nil?: false,
      default: :good,
      public?: true,
      constraints: [one_of: [:good, :device, :service]]

    attribute :serial, :string, public?: true
    attribute :hours, :integer, public?: true
    attribute :discount, :integer, public?: true
    attribute :parts, {:array, Example.Test.ShapedBundles.Part}, public?: true, default: []

    attribute :spec, Example.Test.ShapedBundles.Spec, public?: true

    attribute :photo, :attachment,
      public?: true,
      constraints: [visibility: :private, accepts: [:image], max_size_mb: 10]
  end
end

defmodule Example.Test.ShapedBundles.Address do
  @moduledoc "Where a bundle ships: one sub-form on the bundle's form."
  use Ash.Resource, data_layer: :embedded

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    attribute :country, :string, public?: true
    attribute :region, :string, public?: true
  end
end

defmodule Example.Test.ShapedBundles do
  @moduledoc """
  A bundle whose items' sub-forms change with what is typed into them, and
  the page over it, routed only in the test build.
  `Example.Test.ShapedBundlesLive.Quick`'s `adjust_form/2` says how:

    * an item's `:serial` shows only for a device, which requires it;
    * an item's `:hours` shows only for a service;
    * an item's `:parts`, sub-forms of their own, its `:spec`, a single
      sub-form, and its `:photo` show only for a device; each part's name is
      relabelled;
    * an item's `:discount` is read-only unless the bundle's channel, read
      from the item's parent, is wholesale;
    * the shipping address's `:region` shows only for the country "US", and
      the whole address is hidden for a wholesale bundle.

  In ETS rather than Postgres: nothing here is about what lands in a table.
  The table is shared by every test, so each one finds its rows by the codes
  it made.
  """
  use Ash.Resource,
    domain: Example.Test.ShapedBundles.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  # An upload's key is filed under it.
  resource do
    plural_name :shaped_bundles
  end

  actions do
    defaults [:read, create: [:code, :channel, :items, :shipping]]

    update :update do
      primary? true
      require_atomic? false
      accept [:code, :channel, :items, :shipping]
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

    attribute :channel, :atom,
      allow_nil?: false,
      default: :retail,
      public?: true,
      constraints: [one_of: [:retail, :wholesale]]

    attribute :items, {:array, Example.Test.ShapedBundles.Item}, public?: true, default: []
    attribute :shipping, Example.Test.ShapedBundles.Address, public?: true
  end
end

defmodule Example.Test.ShapedBundlesLive.Quick do
  @moduledoc """
  The page over `Example.Test.ShapedBundles`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.ShapedBundles,
    list: [fields: [:code, :channel]],
    details: [fields: [:code, :channel]]

  alias AshQuick.FormState

  @doc "What each part's name is drawn with."
  def part_label, do: "Part name"

  defp adjust_form(%{action: %{name: action}} = state, _options)
       when action in [:create, :update] do
    state
    |> FormState.update_each([:items], fn item ->
      kind = FormState.value(item, :kind)
      wholesale? = FormState.value(item.parent, :channel) == :wholesale

      item
      |> FormState.hide(:serial, kind != :device)
      |> FormState.require(:serial, kind == :device)
      |> FormState.hide(:hours, kind != :service)
      |> FormState.hide(:parts, kind != :device)
      |> FormState.hide(:photo, kind != :device)
      |> FormState.hide(:spec, kind != :device)
      |> FormState.disable(:discount, not wholesale?)
    end)
    |> FormState.update_each([:items, :parts], &FormState.put_label(&1, :name, part_label()))
    |> FormState.hide(:shipping, FormState.value(state, :channel) == :wholesale)
    |> FormState.update_each([:shipping], fn address ->
      FormState.hide(address, :region, FormState.value(address, :country) != "US")
    end)
  end

  defp adjust_form(state, _options), do: state
end
