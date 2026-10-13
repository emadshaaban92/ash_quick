defmodule Example.Test.RequiredAttachments.Domain do
  @moduledoc "Holds the resource whose actions refuse to save without a file."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.RequiredAttachments do
  @moduledoc """
  A single attachment and an array of them, each required by an action of its
  own, on a create and on an update, and a page over it.

  No resource in this application refuses a save for want of a file, and giving
  one such actions would put them on its demo pages as row and details buttons.
  So the case is built here. `present/1` is enough for the single `:image`; an
  array holding nothing is `[]`, which `present/1` lets through, so `:documents`
  is checked by hand.

  In ETS rather than Postgres, like `Example.Test.DigitsOnly`: nothing here is
  about what lands in a table.
  """
  require Ash.Query

  use Ash.Resource,
    domain: Example.Test.RequiredAttachments.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:code, :name]]

    create :create_with_image do
      accept [:code, :name, :image]
      validate present(:image)
    end

    create :create_with_documents do
      accept [:code, :name, :documents]
      validate &__MODULE__.require_documents/2
    end

    update :attach_image do
      accept [:image]
      require_atomic? false
      validate present(:image)
    end

    update :attach_documents do
      accept [:documents]
      require_atomic? false
      validate &__MODULE__.require_documents/2
    end

    read :index do
      argument :search, :string

      prepare fn query, _context ->
        case Ash.Query.get_argument(query, :search) do
          blank when blank in [nil, ""] -> query
          search -> Ash.Query.filter(query, contains(code, ^search))
        end
      end

      pagination do
        keyset? true
        offset? true
        default_limit 20
        countable :by_default
      end
    end
  end

  @doc false
  def require_documents(changeset, _context) do
    case Ash.Changeset.get_attribute(changeset, :documents) do
      empty when empty in [nil, []] -> {:error, field: :documents, message: "must be present"}
      _documents -> :ok
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
    attribute :name, :string, allow_nil?: false, public?: true

    attribute :image, :attachment,
      public?: true,
      allow_nil?: true,
      constraints: [visibility: :private, accepts: [:image], max_size_mb: 10]

    attribute :documents, {:array, :attachment},
      public?: true,
      allow_nil?: true,
      default: [],
      constraints: [items: [visibility: :private, accepts: [:image, :document], max_size_mb: 10]]
  end
end

defmodule Example.Test.RequiredAttachmentsLive.Quick do
  @moduledoc """
  The page over `Example.Test.RequiredAttachments`, routed only in the test
  build — see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.RequiredAttachments,
    list: [fields: [:code, :name]],
    details: [fields: [:code, :name]]
end
