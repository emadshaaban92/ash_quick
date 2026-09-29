defmodule AshQuick.Test.Activation.Domain do
  @moduledoc """
  Holds the resources the activation attribute is written through.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshQuick.Test.Activation.Activated do
  @moduledoc """
  A resource that declares activation and leaves `:active` to the extension.

  Everything else AshQuick would add is switched off, so a failing write here
  is about `:active` and nothing else.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Activation.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  actions do
    default_accept [:name, :active]
    defaults [:read, :create, :update]
  end

  ash_quick do
    display do
      label :name
    end

    liveness do
      enabled? false
    end

    versioning do
      enabled? false
    end

    bookkeeping do
      inserted_at false
      updated_at false
      inserted_by false
      updated_by false
    end

    activation do
      enabled? true
    end
  end
end

defmodule AshQuick.Test.Activation.OwnActive do
  @moduledoc """
  A resource that declares activation but writes `:active` itself, nullable.

  The extension adds the attribute only when it is absent, so what the
  resource wrote — `allow_nil?` included — is what it keeps.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Activation.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :active, :boolean, public?: true, default: true
  end

  actions do
    default_accept [:name, :active]
    defaults [:read, :create]
  end

  ash_quick do
    display do
      label :name
    end

    liveness do
      enabled? false
    end

    versioning do
      enabled? false
    end

    bookkeeping do
      inserted_at false
      updated_at false
      inserted_by false
      updated_by false
    end

    activation do
      enabled? true
    end
  end
end
