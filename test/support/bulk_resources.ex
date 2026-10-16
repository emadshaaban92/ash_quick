defmodule AshQuick.Test.Bulk.Domain do
  @moduledoc """
  Holds `AshQuick.Test.Bulk.Crate`, the fixture for what a page may name in
  its bulk menu.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshQuick.Test.Bulk.Label do
  @moduledoc "An embed carrying an upload, so an upload can sit one level down."
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :caption, :string, public?: true

    attribute :photo, AshQuick.AshTypes.Attachment,
      public?: true,
      constraints: [visibility: :public, accepts: [:image]]
  end
end

defmodule AshQuick.Test.Bulk.Crate do
  @moduledoc """
  One action of every kind a bulk menu may be asked to name: updates and
  destroys with and without input, ones that take uploads directly or inside
  an embed, a private one, and a read and a create.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Bulk.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :labels, {:array, AshQuick.Test.Bulk.Label}, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:name]]

    read :index do
      argument :search, :string

      pagination do
        keyset? true
        offset? true
        default_limit 20
        countable :by_default
      end
    end

    update :rename do
      accept [:name]
    end

    update :close do
      accept []
    end

    update :attach do
      accept []

      argument :scan, AshQuick.AshTypes.Attachment,
        constraints: [visibility: :private, accepts: [:document]]
    end

    update :relabel do
      accept [:labels]
      require_atomic? false
    end

    update :recount do
      public? false
      accept []
    end

    destroy :retire do
      argument :reason, :string, allow_nil?: false
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

    versioning do
      enabled? false
    end

    audit do
      enabled? false
    end
  end
end
