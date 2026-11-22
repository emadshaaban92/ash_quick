defmodule Example.Test.TwoFileRows.Domain do
  @moduledoc "Holds the resource whose rows each carry two kinds of file."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.TwoFileRows.Row do
  @moduledoc """
  One row with a photo, which takes only images, and a scan, which takes
  documents too.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :photo, :attachment,
      public?: true,
      allow_nil?: true,
      constraints: [visibility: :private, accepts: [:image], max_size_mb: 10]

    attribute :scan, :attachment,
      public?: true,
      allow_nil?: true,
      constraints: [visibility: :private, accepts: [:image, :document], max_size_mb: 10]
  end
end

defmodule Example.Test.TwoFileRows do
  @moduledoc """
  An embedded array whose rows hold two attachment fields that take different
  files, beside a root `:cover` that takes only images. `:add_photos` folds
  an upload argument onto the same rows.

  A row's upload is consumed only at save, so until then the key its presign
  minted is bound to `:rows` by the presign alone, which is what lets a post
  name it on its own row before the save. Bound to the top-level `:rows`, a
  key can still move between the fields of a row.

  In ETS rather than Postgres, like `Example.Test.RequiredAttachments`.
  """
  use Ash.Resource,
    domain: Example.Test.TwoFileRows.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  require Ash.Query

  actions do
    defaults [:read, create: [:code, :cover, :rows], update: [:code, :cover, :rows]]

    # Photos picked here are folded onto `:rows` by the action, after the
    # rows the form draws, and the action takes `:rows` itself. The argument
    # is spent as it folds, so applied twice it adds each photo twice. The
    # save does not keep them yet (#260): the photo's key is issued for
    # `:new_photos`, and the form posts it under `rows`.
    update :add_photos do
      accept [:rows]
      require_atomic? false

      argument :new_photos, {:array, :attachment},
        constraints: [items: [visibility: :private, accepts: [:image], max_size_mb: 10]]

      change fn changeset, _context ->
        added =
          changeset
          |> Ash.Changeset.get_argument(:new_photos)
          |> List.wrap()
          |> Enum.map(&%{photo: &1})

        rows = Ash.Changeset.get_attribute(changeset, :rows) || []
        Ash.Changeset.change_attribute(changeset, :rows, rows ++ added)
      end
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

    attribute :cover, :attachment,
      public?: true,
      allow_nil?: true,
      constraints: [visibility: :private, accepts: [:image], max_size_mb: 10]

    attribute :rows, {:array, Example.Test.TwoFileRows.Row}, public?: true, default: []
  end
end

defmodule Example.Test.TwoFileRowsLive.Quick do
  @moduledoc """
  The page over `Example.Test.TwoFileRows`, routed only in the test build — see
  the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.TwoFileRows,
    list: [fields: [:code]],
    details: [fields: [:code]]
end
