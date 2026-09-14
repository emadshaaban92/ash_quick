defmodule AshQuick.Test.Gen.Domain do
  @moduledoc """
  Holds the fixtures the generators read. Nothing here is ever written — the
  generators only introspect.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshQuick.Test.Gen.Widget do
  @moduledoc """
  An ordinary adopted resource: the extension, a create action, and a mix of
  attributes the starter field list has to choose between.

  `:secret` is sensitive, and `:internal` is not public — neither belongs on a
  page a generator wrote without being asked.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Gen.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  resource do
    plural_name :widgets
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update]
  end

  ash_quick do
    liveness do
      enabled? false
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :sku, :string, public?: true
    attribute :name, :string, public?: true
    attribute :secret, :string, public?: true, sensitive?: true
    attribute :internal, :string
  end
end

defmodule AshQuick.Test.Gen.Ledger do
  @moduledoc """
  A resource nothing creates by hand — the shape `except: [:create]` exists for.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Gen.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  resource do
    plural_name :ledger_entries
  end

  actions do
    defaults [:read]
  end

  ash_quick do
    liveness do
      enabled? false
    end

    versioning do
      enabled? false
    end

    bookkeeping do
      created_by false
      updated_by false
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :amount, :integer, public?: true
  end
end
