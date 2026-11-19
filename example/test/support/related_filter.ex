defmodule Example.Test.RelatedFilter.Owner do
  @moduledoc """
  Whom an `Example.Test.RelatedFilter.Item` belongs to, which the item's
  filter reaches through `owner`: a name, a tier picked from a fixed set one
  of whose values the owner labels, a pin only an admin may see, a note only
  an admin sees on a gold owner, a motto only the `:index` read shows, and a
  flag hiding the owner itself from anyone but an admin. `:index` searches
  owners by name, for a filter row picking owners.

  In ETS, so the paths are read by Ash itself; `Example.Catalog.Product`'s
  brand covers AshPostgres.
  """
  use Ash.Resource,
    domain: Example.Test.FilterFields.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  field_policies do
    field_policy :pin do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    field_policy :note do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if expr(tier == :bronze)
    end

    field_policy :motto do
      forbid_unless action(:index)
      authorize_if always()
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [:read]

    read :index do
      argument :search, :string
      filter expr(is_nil(^arg(:search)) or contains(name, ^arg(:search)))
      pagination offset?: true, required?: false, default_limit: 20
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if expr(hidden == false)
    end
  end

  ash_quick do
    display do
      label :name
    end

    labels do
      label :tier, "Level"
      label :tier, :gold, "Gold member"
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
    attribute :tier, :atom, public?: true, constraints: [one_of: [:bronze, :gold]]
    attribute :pin, :string, public?: true
    attribute :note, :string, public?: true
    attribute :motto, :string, public?: true
    attribute :hidden, :boolean, public?: true, allow_nil?: false, default: false
  end
end

defmodule Example.Test.RelatedFilter.Ledger do
  @moduledoc """
  A resource with no read action, which `Example.Test.RelatedFilter.Item`
  belongs to through `ledger`: no read could ask of a ledger, so the filter
  offers none of its fields.
  """
  use Ash.Resource,
    domain: Example.Test.FilterFields.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults create: [:name]
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, public?: true
  end
end

defmodule Example.Test.RelatedFilter.Vault do
  @moduledoc """
  A resource only an admin reads directly, and anyone reads through an
  `Example.Test.RelatedFilter.Item`'s `vault`: its read policy and its code's
  field policy both hold through `accessing_from/2`. So the item's filter
  offers its name and code to an editor, as their columns show them, though
  no read of the vault itself would, and so no row picking vaults, which
  would search them directly.
  """
  use Ash.Resource,
    domain: Example.Test.FilterFields.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  field_policies do
    field_policy :code do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if accessing_from(Example.Test.RelatedFilter.Item, :vault)
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [:read]

    read :index do
      argument :search, :string
      pagination offset?: true, required?: false, default_limit: 20
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if accessing_from(Example.Test.RelatedFilter.Item, :vault)
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
    attribute :code, :string, public?: true
  end
end

defmodule Example.Test.RelatedFilter.Locked do
  @moduledoc """
  A resource only an admin reads, by any route: an
  `Example.Test.RelatedFilter.Item`'s `locked` gives an editor no way in, so
  the item's filter offers an editor none of its fields, nor a row picking
  locked records.
  """
  use Ash.Resource,
    domain: Example.Test.FilterFields.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  actions do
    defaults [:read]

    read :index do
      argument :search, :string
      pagination offset?: true, required?: false, default_limit: 20
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
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

defmodule Example.Test.RelatedFilter.TagGroup do
  @moduledoc """
  What an `Example.Test.RelatedFilter.Tag` belongs to, which an item's filter
  picks through its tags. Searched by name.
  """
  use Ash.Resource,
    domain: Example.Test.FilterFields.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read]

    read :index do
      argument :search, :string
      filter expr(is_nil(^arg(:search)) or contains(name, ^arg(:search)))
      pagination offset?: true, required?: false, default_limit: 20
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

defmodule Example.Test.RelatedFilter.Tag do
  @moduledoc """
  A tag an `Example.Test.RelatedFilter.Item` has many of, in a tag group, and
  a flag hiding it from anyone but an admin. Searched by name, and hinted by
  its code, since two tags can share a name.
  """
  use Ash.Resource,
    domain: Example.Test.FilterFields.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  actions do
    defaults [:read]

    read :index do
      argument :search, :string
      filter expr(is_nil(^arg(:search)) or contains(name, ^arg(:search)))
      pagination offset?: true, required?: false, default_limit: 20
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if expr(hidden == false)
    end
  end

  ash_quick do
    display do
      label :name
      hint :code
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
    attribute :code, :string, public?: true
    attribute :hidden, :boolean, public?: true, allow_nil?: false, default: false
  end

  relationships do
    belongs_to :tag_group, Example.Test.RelatedFilter.TagGroup, public?: true
  end
end

defmodule Example.Test.RelatedFilter.ItemTag do
  @moduledoc "Joins an `Example.Test.RelatedFilter.Item` to its tags."
  use Ash.Resource,
    domain: Example.Test.FilterFields.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read]
  end

  attributes do
    uuid_v7_primary_key :id
  end

  relationships do
    belongs_to :item, Example.Test.RelatedFilter.Item, allow_nil?: false
    belongs_to :tag, Example.Test.RelatedFilter.Tag, allow_nil?: false
  end
end

defmodule Example.Test.RelatedFilter.Item do
  @moduledoc """
  A resource whose list is filtered by its owner's fields, through `owner`, a
  public belongs_to, and its steward's, through `steward`, one that reads the
  owner with `:index`. `keeper`, a private one, `ledger`, one to a resource
  with no read, and `children`, a has-many, are what a filter cannot reach
  a field through. A row can pick its owner, its tags, a many-to-many, the
  tags' groups, its children and its locked record.

  Rows are seeded rather than created, so no form here edits the owner, and
  the owner is asked for no dropdown.
  """
  use Ash.Resource,
    domain: Example.Test.FilterFields.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  actions do
    defaults [:read]

    read :index do
      argument :search, :string

      pagination do
        offset? true
        default_limit 250
        countable :by_default
      end
    end
  end

  policies do
    policy always() do
      authorize_if always()
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
    belongs_to :owner, Example.Test.RelatedFilter.Owner, public?: true
    belongs_to :steward, Example.Test.RelatedFilter.Owner, public?: true, read_action: :index
    belongs_to :keeper, Example.Test.RelatedFilter.Owner
    belongs_to :ledger, Example.Test.RelatedFilter.Ledger, public?: true
    belongs_to :vault, Example.Test.RelatedFilter.Vault, public?: true
    belongs_to :locked, Example.Test.RelatedFilter.Locked, public?: true
    belongs_to :parent, __MODULE__, public?: true
    has_many :children, __MODULE__, destination_attribute: :parent_id, public?: true

    many_to_many :tags, Example.Test.RelatedFilter.Tag,
      through: Example.Test.RelatedFilter.ItemTag,
      source_attribute_on_join_resource: :item_id,
      destination_attribute_on_join_resource: :tag_id,
      public?: true
  end
end

defmodule Example.Test.RelatedFilterLive.Quick do
  @moduledoc """
  The page over `Example.Test.RelatedFilter.Item` whose filter offers the
  item's code, its owner's name, tier, pin, note and motto, and its steward's
  motto, which only the steward's `:index` read shows. Routed only in the
  test build.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.RelatedFilter.Item,
    list: [
      fields: [:code, {[owner: :name], label: "Owner"}],
      filterable: [
        :code,
        owner: :name,
        owner: :tier,
        owner: :pin,
        owner: :note,
        owner: :motto,
        steward: :motto
      ]
    ],
    details: [fields: [:code]]
end

defmodule Example.Test.RelatedFilterDefaultLive.Quick do
  @moduledoc """
  The page over `Example.Test.RelatedFilter.Item` that names no
  `filterable:`, so its filter offers the item's own fields only. Routed only
  in the test build.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.RelatedFilter.Item,
    list: [fields: [:code, {[owner: :name], label: "Owner"}]],
    details: [fields: [:code]]
end

defmodule Example.Test.RelatedFilterDefaultsLive.Quick do
  @moduledoc """
  The page over `Example.Test.RelatedFilter.Item` whose filter offers the
  fields it would offer unsaid, the item's own, and its owner's name after
  them. Routed only in the test build.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.RelatedFilter.Item,
    list: [
      fields: [:code, {[owner: :name], label: "Owner"}],
      filterable: [:defaults, owner: :name]
    ],
    details: [fields: [:code]]
end

defmodule Example.Test.VaultFilterLive.Quick do
  @moduledoc """
  The page over `Example.Test.RelatedFilter.Item` whose filter offers the
  item's code, its vault's name and code, which a reader reaches only
  through the item, and its locked record's name, which only an admin reads.
  Routed only in the test build.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.RelatedFilter.Item,
    list: [
      fields: [:code, {[vault: :code], label: "Vault code"}],
      filterable: [:code, vault: :name, vault: :code, locked: :name]
    ],
    details: [fields: [:code]]
end

defmodule Example.Test.RecordFilterLive.Quick do
  @moduledoc """
  The page over `Example.Test.RelatedFilter.Item` whose filter picks related
  records: its owner, its tags, its tags' groups, its children, its vault
  and its locked record. Routed only in the test build.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.RelatedFilter.Item,
    list: [
      fields: [:code],
      filterable: [:code, :owner, :tags, [tags: :tag_group], :children, :vault, :locked]
    ],
    details: [fields: [:code]]
end

defmodule Example.Test.BrandRecordFilterLive.Quick do
  @moduledoc """
  The page over `Example.Catalog.Product` whose filter picks a product's
  brand, which every product has, and its store, which one need not, read by
  AshPostgres. Routed only in the test build.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Catalog.Product,
    list: [fields: [:sku, {[brand: :name], label: "Brand"}], filterable: [:sku, :brand, :store]],
    details: [fields: [:sku]]
end

defmodule Example.Test.BrandFilterLive.Quick do
  @moduledoc """
  The page over `Example.Catalog.Product` whose filter offers a product's sku,
  its brand's name and code, and its store's name, a store a product need not
  have, so a path is read by AshPostgres. Routed only in the test build.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Catalog.Product,
    list: [
      fields: [:sku, {[brand: :name], label: "Brand"}],
      filterable: [:sku, brand: :name, brand: :code, store: :name]
    ],
    details: [fields: [:sku]]
end
