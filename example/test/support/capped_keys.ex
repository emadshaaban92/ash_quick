defmodule Example.Test.CappedKeys.Domain do
  @moduledoc "Holds the resource whose lookup action reads at most two rows."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.CappedKeys do
  @moduledoc """
  A resource whose lookup action caps a page at two rows, for the form
  pickers that name the keys a field holds (`AshQuick.LiveView.FormRecords`):
  Ash clamps a larger page to the cap, so naming more keys takes several
  reads. In ETS; only `AshQuick.LiveView.FormRecordsTest` writes to it.
  """
  use Ash.Resource,
    domain: Example.Test.CappedKeys.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:code]]

    read :index do
      argument :search, :string

      pagination do
        offset? true
        default_limit 2
        max_page_size 2
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
end

defmodule Example.Test.RefusedLookups do
  @moduledoc """
  A resource whose lookup action fails every read, for the form pickers
  (`AshQuick.LiveView.FormRecords`): a refused read is logged and offers and
  names nothing.
  """
  use Ash.Resource,
    domain: Example.Test.CappedKeys.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:code]]

    read :index do
      argument :search, :string
      prepare fn query, _context -> Ash.Query.add_error(query, "refused on purpose") end

      pagination do
        offset? true
        default_limit 20
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
end
