defmodule AshQuick.Test.ListInputs.Domain do
  @moduledoc """
  Holds the fixture below, which is never read: only the forms a QuickView
  would build over it are checked.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshQuick.Test.ListInputs.Mark do
  @moduledoc "A new type over a bare string, which counts as what it wraps."
  use Ash.Type.NewType, subtype_of: :string
end

defmodule AshQuick.Test.ListInputs.Colour do
  @moduledoc false
  use Ash.Type.Enum, values: [:red, :green]
end

defmodule AshQuick.Test.ListInputs.Note do
  @moduledoc "What `Record`'s `:annotate` manages, through a list of maps."
  use Ash.Resource,
    domain: AshQuick.Test.ListInputs.Domain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :body, :string, public?: true
    attribute :record_id, :uuid, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:body, :record_id], update: [:body]]
  end
end

defmodule AshQuick.Test.ListInputs.Record do
  @moduledoc """
  Lists a form can and cannot save, on actions a page offers and one it never
  does:

    * `:create` takes `:marks`, atoms with no `one_of`, beside `:picked` (atoms
      with `one_of`) and `:colours` (an enum), which are selects.
    * `:retag` takes `:labels`, strings, `:codes`, a new type over a string,
      `:flags`, booleans, `:times` and `:extras`, maps, as arguments.
    * `:annotate` takes `:notes`, maps too, but manages a relationship through
      them, so each is a sub-form.
    * `:stamp` takes `:tags`, strings, and is private.
  """
  use Ash.Resource,
    domain: AshQuick.Test.ListInputs.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :marks, {:array, :atom}, public?: true
    attribute :picked, {:array, :atom}, public?: true, constraints: [items: [one_of: [:a, :b]]]
    attribute :colours, {:array, AshQuick.Test.ListInputs.Colour}, public?: true
    attribute :tags, {:array, :string}, public?: true
  end

  actions do
    defaults [:read, create: [:name, :marks, :picked, :colours]]

    read :index do
      argument :search, :string

      pagination do
        keyset? true
        offset? true
        default_limit 20
        countable :by_default
      end
    end

    update :retag do
      argument :labels, {:array, :string}
      argument :codes, {:array, AshQuick.Test.ListInputs.Mark}
      argument :flags, {:array, :boolean}
      argument :times, {:array, :time_usec}
      argument :extras, {:array, :map}
    end

    update :annotate do
      require_atomic? false
      argument :notes, {:array, :map}
      change manage_relationship(:notes, type: :direct_control)
    end

    update :stamp do
      public? false
      accept [:tags]
    end
  end

  relationships do
    has_many :notes, AshQuick.Test.ListInputs.Note, public?: true
  end

  ash_quick do
    bookkeeping do
      inserted_at false
      updated_at false
      inserted_by false
      updated_by false
    end

    versioning do
      enabled? false
    end

    audit do
      enabled? false
    end

    liveness do
      enabled? false
    end
  end
end
