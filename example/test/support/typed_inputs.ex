defmodule Example.Test.TypedInputs.Domain do
  @moduledoc "Holds the resource whose fields each get a typed form input."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.TypedInputs.Count do
  @moduledoc "A count that is never negative, as a type of its own."
  use Ash.Type.NewType, subtype_of: :integer, constraints: [min: 0]
end

defmodule Example.Test.TypedInputs.Depth do
  @moduledoc """
  An embedded value inside `Example.Test.TypedInputs.Dims`. AshPhoenix builds
  its sub-form's config only when the sub-form is added, through the outer
  one's `updater`.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :depth, :integer, public?: true
  end
end

defmodule Example.Test.TypedInputs.Dims do
  @moduledoc "An embedded value holding a number, drawn as a sub-form."
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :width, :integer, public?: true
    attribute :label, :string, public?: true
    attribute :inner, Example.Test.TypedInputs.Depth, public?: true
  end
end

defmodule Example.Test.TypedInputs.Part do
  @moduledoc "A related record holding a number, added through a managed relationship."
  use Ash.Resource,
    domain: Example.Test.TypedInputs.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy, create: [:count, :typed_input_id], update: [:count]]
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :count, :integer, public?: true
  end

  relationships do
    belongs_to :typed_input, Example.Test.TypedInputs, public?: true
  end
end

defmodule Example.Test.TypedInputs do
  @moduledoc """
  A field of each type a form draws a typed input for, and a page over them:
  numbers that may and may not be negative, a number through a NewType, a
  date, a time to the second and one to the microsecond, a naive datetime,
  and strings with length limits counted each way Ash counts them.

  In ETS rather than Postgres, like `Example.Test.DatedEntries`.
  """
  use Ash.Resource,
    domain: Example.Test.TypedInputs.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  @inputs [
    :code,
    :quantity,
    :stock,
    :boxes,
    :weight,
    :ratio,
    :balance,
    :due_on,
    :opens_at,
    :precise_at,
    :logged_at,
    :short_name,
    :tag,
    :byte_name,
    :glyph_name
  ]

  actions do
    defaults [:read, create: @inputs, update: @inputs]

    # An argument that holds a number is read as one too.
    create :with_tally do
      accept [:code]
      argument :tally, :integer, allow_nil?: false
      change set_attribute(:quantity, arg(:tally))
    end

    # An embed's and a related record's numbers, through sub-forms.
    create :with_parts do
      accept [:code, :dims]
      argument :parts, {:array, :map}, default: []
      change manage_relationship(:parts, type: :create)
    end

    update :resize do
      accept [:dims]
    end

    # Run over a selection through the bulk modal.
    update :restock do
      accept [:stock]
    end

    read :index do
      argument :search, :string

      pagination do
        keyset? true
        offset? true
        default_limit 250
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
    attribute :quantity, :integer, public?: true
    attribute :stock, :integer, public?: true, constraints: [min: 0]
    attribute :boxes, Example.Test.TypedInputs.Count, public?: true
    attribute :weight, :decimal, public?: true, constraints: [greater_than: 0]
    attribute :ratio, :float, public?: true, constraints: [min: 0.0, max: 1.0]
    attribute :balance, :decimal, public?: true, constraints: [min: -100]
    attribute :due_on, :date, public?: true
    attribute :opens_at, :time, public?: true
    attribute :precise_at, :time_usec, public?: true
    attribute :logged_at, :naive_datetime, public?: true
    attribute :short_name, :string, public?: true, constraints: [max_length: 12, min_length: 2]
    attribute :tag, :ci_string, public?: true, constraints: [max_length: 8]

    attribute :byte_name, :string,
      public?: true,
      constraints: [max_length: 16, min_length: 4, length_count: :bytes]

    attribute :dims, Example.Test.TypedInputs.Dims, public?: true

    attribute :glyph_name, :string,
      public?: true,
      constraints: [max_length: 6, min_length: 1, length_count: :graphemes]
  end

  relationships do
    has_many :parts, Example.Test.TypedInputs.Part,
      public?: true,
      destination_attribute: :typed_input_id
  end
end

defmodule Example.Test.TypedInputsLive.Quick do
  @moduledoc """
  The page over `Example.Test.TypedInputs`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.TypedInputs,
    list: [
      fields: [:code, :quantity, :stock, :due_on, :opens_at, :logged_at],
      bulk_actions: [:restock]
    ],
    details: [fields: [:code, :quantity, :stock, :weight, :ratio, :due_on, :logged_at]]
end
