defmodule AshQuick.Test.RelationshipArgs.Domain do
  @moduledoc """
  Holds the fixtures below, which are never read — only their actions are
  introspected, for which relationship an id-list argument edits.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshQuick.Test.RelationshipArgs.Tag do
  @moduledoc false
  use Ash.Resource,
    domain: AshQuick.Test.RelationshipArgs.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  # No lookup action, so a page with a dropdown onto it refuses to compile:
  # that refusal is how a test sees the dropdown was found.
  actions do
    defaults [:read, :create]
  end

  ash_quick do
    bookkeeping do
      inserted_at false
      updated_at false
      inserted_by false
      updated_by false
    end

    liveness do
      enabled? false
    end
  end
end

defmodule AshQuick.Test.RelationshipArgs.Tagging do
  @moduledoc false
  use Ash.Resource,
    domain: AshQuick.Test.RelationshipArgs.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy, create: [:post_id, :tag_id]]
  end

  relationships do
    belongs_to :post, AshQuick.Test.RelationshipArgs.Post,
      primary_key?: true,
      allow_nil?: false,
      public?: true

    belongs_to :tag, AshQuick.Test.RelationshipArgs.Tag,
      primary_key?: true,
      allow_nil?: false,
      public?: true
  end
end

defmodule AshQuick.Test.RelationshipArgs.Post do
  @moduledoc """
  Each action names its id-list argument differently:

    * `:create` edits `:tags` through an argument of the same name.
    * `:relabel` edits `:labels` through `:picked`.
    * `:legacy` has no `manage_relationship`: `:tags_ids` still edits `:tags`
      by its name, and `:legacy_ids` names no relationship at all.
    * `:everywhere` edits `:labels` through a global change.
  """
  use Ash.Resource,
    domain: AshQuick.Test.RelationshipArgs.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  alias AshQuick.Test.RelationshipArgs.{Tag, Tagging}

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  relationships do
    many_to_many :tags, Tag do
      through Tagging
      source_attribute_on_join_resource :post_id
      destination_attribute_on_join_resource :tag_id
      public? true
    end

    many_to_many :labels, Tag do
      through Tagging
      source_attribute_on_join_resource :post_id
      destination_attribute_on_join_resource :tag_id
      public? true
    end
  end

  changes do
    change manage_relationship(:everywhere, :labels, type: :append_and_remove),
      on: [:update]
  end

  actions do
    defaults [:read]

    read :index do
      argument :search, :string

      pagination do
        keyset? true
        offset? true
        default_limit 20
        countable :by_default
      end
    end

    create :create do
      accept [:name]
      argument :tags, {:array, :uuid}
      change manage_relationship(:tags, type: :append_and_remove)
    end

    update :relabel do
      require_atomic? false
      argument :picked, {:array, :uuid}
      change manage_relationship(:picked, :labels, type: :append_and_remove)
    end

    update :legacy do
      argument :tags_ids, {:array, :uuid}
      argument :legacy_ids, {:array, :uuid}
    end

    update :everywhere do
      require_atomic? false
      argument :everywhere, {:array, :uuid}
    end
  end

  ash_quick do
    bookkeeping do
      inserted_at false
      updated_at false
      inserted_by false
      updated_by false
    end

    liveness do
      enabled? false
    end
  end
end
