defmodule AshQuick.Test.Linked.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshQuick.Test.Linked.Off do
  @moduledoc false
  # The capabilities these fixtures do not exercise, turned off together.
  defmacro __using__(_opts) do
    quote do
      ets do
        private? true
      end

      ash_quick do
        versioning do
          enabled? false
        end

        audit do
          enabled? false
        end

        liveness do
          enabled? false
        end

        bookkeeping do
          inserted_at false
          updated_at false
          inserted_by false
          updated_by false
        end
      end
    end
  end
end

defmodule AshQuick.Test.Linked.Maker do
  @moduledoc "Labelled by a name two makers can share, and told apart by a code."
  use Ash.Resource,
    domain: AshQuick.Test.Linked.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  use AshQuick.Test.Linked.Off

  ash_quick do
    display do
      hint :code
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :code, :string, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshQuick.Test.Linked.Vault do
  @moduledoc """
  Labelled by a field that is masked wherever it renders, and told apart by a
  code — so a link to one has an accessible name the label could leak into.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Linked.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  use AshQuick.Test.Linked.Off

  ash_quick do
    display do
      label :pin
      hint :code
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :pin, :string, public?: true, sensitive?: true
    attribute :code, :string, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshQuick.Test.Linked.Assembly do
  @moduledoc "One relationship further from the maker, for a nested path."
  use Ash.Resource,
    domain: AshQuick.Test.Linked.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  use AshQuick.Test.Linked.Off

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  relationships do
    belongs_to :maker, AshQuick.Test.Linked.Maker, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshQuick.Test.Linked.Part do
  @moduledoc "Reaches a maker directly and through an assembly, a vault and a locker."
  use Ash.Resource,
    domain: AshQuick.Test.Linked.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  use AshQuick.Test.Linked.Off

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  relationships do
    belongs_to :maker, AshQuick.Test.Linked.Maker, public?: true
    belongs_to :vault, AshQuick.Test.Linked.Vault, public?: true
    belongs_to :assembly, AshQuick.Test.Linked.Assembly, public?: true
    belongs_to :locker, AshQuick.Test.Linked.Locker, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshQuick.Test.Linked.Locker do
  @moduledoc "Labelled plainly, and told apart by a field that is masked."
  use Ash.Resource,
    domain: AshQuick.Test.Linked.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  use AshQuick.Test.Linked.Off

  ash_quick do
    display do
      hint :combination
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :combination, :string, public?: true, sensitive?: true
  end

  actions do
    defaults [:read]
  end
end
