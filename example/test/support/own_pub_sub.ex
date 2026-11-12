defmodule Example.Test.OwnPubSub.Domain do
  @moduledoc "Holds the resources that write their own `pub_sub` block."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.OwnPubSub.ExtensionOnly do
  @moduledoc """
  A `pub_sub` block of its own, written with `extensions: [AshQuick]` and no
  `notifiers:` line: the extension brings the DSL in.
  """
  use Ash.Resource,
    domain: Example.Test.OwnPubSub.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  actions do
    defaults [:read, create: [:name]]
  end

  ash_quick do
    display do
      label :name
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

  pub_sub do
    module ExampleWeb.Endpoint

    publish :create, ["made", :id]
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end
end

defmodule Example.Test.OwnPubSub.AlsoNotifier do
  @moduledoc """
  The same block on a resource that still lists
  `notifiers: [Ash.Notifier.PubSub]`, the way hosts had to before the extension
  brought the DSL in.
  """
  use Ash.Resource,
    domain: Example.Test.OwnPubSub.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick],
    notifiers: [Ash.Notifier.PubSub]

  ets do
    private? true
  end

  actions do
    defaults [:read, create: [:name]]
  end

  ash_quick do
    display do
      label :name
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

  pub_sub do
    module ExampleWeb.Endpoint

    publish :create, ["made", :id]
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end
end
