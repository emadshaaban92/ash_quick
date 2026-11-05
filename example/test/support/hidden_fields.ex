defmodule Example.Test.HiddenFields.Domain do
  @moduledoc "Holds the resource whose update form offers fields a reader may not see."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.HiddenFields.Owner do
  @moduledoc "Whom an `Example.Test.HiddenFields` row belongs to."
  use Ash.Resource,
    domain: Example.Test.HiddenFields.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:name]]

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

defmodule Example.Test.HiddenFields.Line do
  @moduledoc "A record `Example.Test.HiddenFields` manages as a relationship."
  use Ash.Resource,
    domain: Example.Test.HiddenFields.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy, create: [:label, :hidden_fields_id], update: [:label]]
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :label, :string, allow_nil?: true, public?: true
  end

  relationships do
    belongs_to :hidden_fields, Example.Test.HiddenFields, public?: true, allow_nil?: true
  end
end

defmodule Example.Test.HiddenFields.Keeper do
  @moduledoc "A related record, edited in a sub-form, whose `:phone` an editor may not see."
  use Ash.Resource,
    domain: Example.Test.HiddenFields.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  field_policies do
    field_policy :phone do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [:read, :destroy, create: [:name, :phone], update: [:name, :phone]]

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

  policies do
    policy always() do
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
    attribute :name, :string, allow_nil?: true, public?: true
    attribute :phone, :string, allow_nil?: true, public?: true
  end
end

defmodule Example.Test.HiddenFields.Address do
  @moduledoc "A single embed under a field an editor may not see."
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :street, :string, allow_nil?: true, public?: true
  end
end

defmodule Example.Test.HiddenFields do
  @moduledoc """
  A resource whose updates accept fields a field policy hides, and a page over
  it.

  `:memo` is seen by anyone on an open record, and by an admin on every record.
  Every other field `:edit` accepts but `:code`, of each shape a form handles
  its own way (a number, a single attachment, a list of them, an embed, and
  the `owner_id` behind a dropdown), is seen by an admin only. No policy limits
  writing, so the action takes all of them from whoever runs it: what the form
  draws, uploads and carries is the page's choice, which is what is under test.
  `:set_salary` accepts `:salary` alone, so an editor may change nothing it
  offers. `:retag` is `:edit` without its uploads, for the bulk menu,
  `:probe_arg` takes an argument named `:salary` (in bulk too), `:probe_tags`
  a list argument named `:tags`, `:edit_lines` manages related lines, and
  `:edit_keeper` edits a related keeper whose `:phone` only an admin sees.

  In ETS rather than Postgres: nothing here is about what lands in a table.
  """
  use Ash.Resource,
    domain: Example.Test.HiddenFields.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  field_policies do
    field_policy [:salary, :photo, :documents, :address, :owner_id, :tags] do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    field_policy :memo do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if expr(open == true)
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [
      :read,
      create: [
        :code,
        :salary,
        :memo,
        :open,
        :photo,
        :documents,
        :address,
        :owner_id,
        :tags,
        :keeper_id
      ]
    ]

    read :index do
      argument :search, :string

      pagination do
        keyset? true
        offset? true
        default_limit 20
        countable :by_default
      end
    end

    update :edit do
      accept [:code, :salary, :memo, :photo, :documents, :address, :owner_id]
    end

    update :set_salary do
      accept [:salary]
    end

    # `:edit` without the uploads, which a bulk menu refuses.
    update :retag do
      accept [:code, :salary, :memo, :address, :owner_id]
    end

    # Manages `:lines`, on a record whose embed an editor may not see.
    update :edit_lines do
      accept [:code]
      argument :lines, {:array, :map}
      require_atomic? false
      change manage_relationship(:lines, type: :direct_control)
    end

    # An argument named like a hidden attribute, which the form prefills from
    # it.
    update :probe_arg do
      accept [:code]
      argument :salary, :integer
    end

    # A list argument named like a hidden attribute, which it writes back: a
    # form that sent it, even as the `[]` an emptied list posts, would empty
    # the hidden `:tags`.
    update :probe_tags do
      accept [:code]
      argument :tags, {:array, :atom}, constraints: [items: [one_of: [:a, :b]]]
      require_atomic? false

      change fn changeset, _context ->
        case Ash.Changeset.fetch_argument(changeset, :tags) do
          {:ok, tags} when is_list(tags) -> Ash.Changeset.change_attribute(changeset, :tags, tags)
          _none -> changeset
        end
      end
    end

    # Edits `:keeper` in a sub-form over the record loaded on the page.
    update :edit_keeper do
      accept [:code]
      argument :keeper, :map
      require_atomic? false
      change manage_relationship(:keeper, type: :direct_control)
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
    attribute :salary, :integer, public?: true
    attribute :memo, :string, public?: true
    attribute :open, :boolean, allow_nil?: false, default: true, public?: true

    attribute :photo, :attachment,
      public?: true,
      allow_nil?: true,
      constraints: [visibility: :private, accepts: [:image], max_size_mb: 10]

    attribute :documents, {:array, :attachment},
      public?: true,
      allow_nil?: true,
      default: [],
      constraints: [items: [visibility: :private, accepts: [:image, :document], max_size_mb: 10]]

    attribute :address, Example.Test.HiddenFields.Address, allow_nil?: true, public?: true

    attribute :tags, {:array, :atom},
      public?: true,
      allow_nil?: true,
      constraints: [items: [one_of: [:a, :b]]]
  end

  relationships do
    belongs_to :owner, Example.Test.HiddenFields.Owner, public?: true, allow_nil?: true
    has_many :lines, Example.Test.HiddenFields.Line, public?: true
    belongs_to :keeper, Example.Test.HiddenFields.Keeper, public?: true, allow_nil?: true
  end
end

defmodule Example.Test.HiddenFieldsLive.Quick do
  @moduledoc """
  The page over `Example.Test.HiddenFields`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.HiddenFields,
    load: [:keeper],
    list: [fields: [:code, :salary, :memo], bulk_actions: [:retag, :probe_arg]],
    details: [fields: [:code, :salary, :memo]]
end
