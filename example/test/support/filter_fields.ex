defmodule Example.Test.FilterFields.Domain do
  @moduledoc "Holds the resource the list's filter is exercised on."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.FilterFields do
  @moduledoc """
  A resource for the list's filter: a code to match the start of, a timestamp
  to compare, a salary only an admin may see, which the filter offers to no
  one else, a flag picked as Yes or No, a state typed in as an atom, a stage
  picked from a fixed set, an OCR status picked from a fixed set one of whose
  values the resource labels, a note that may be left empty or blank, a memo
  hidden on some rows, a sum that is never empty, topics, a list each item of
  which is picked from a fixed set, a fee in a currency, a deposit in one with no
  default, and tags, a list of
  strings, and a reference Ash filters by simple equality only, neither of
  which it offers anyone.

  In ETS rather than Postgres, so Starts With is read by Ash itself rather
  than by a SQL `LIKE`.
  """
  use Ash.Resource,
    domain: Example.Test.FilterFields.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  field_policies do
    field_policy :salary do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Seen by anyone on an active row, and by an admin on every row: the filter
    # offers it to everyone, but Is Empty only to an admin.
    field_policy :memo do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if expr(active == true)
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [
      :read,
      create: [
        :code,
        :stamped_at,
        :salary,
        :active,
        :stage,
        :ocr_status,
        :note,
        :memo,
        :topics,
        :fee,
        :deposit,
        :reference,
        :parent_id
      ]
    ]

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

  policies do
    policy always() do
      authorize_if always()
    end
  end

  ash_quick do
    display do
      label :code
    end

    labels do
      label :ocr_status, "Status"
      label :ocr_status, :failed, "Couldn't read"
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
    attribute :stamped_at, :utc_datetime_usec, public?: true
    attribute :salary, :integer, public?: true
    attribute :active, :boolean, public?: true
    # An atom with no fixed set, typed in, whose value need not be an atom the
    # VM knows.
    attribute :state, :atom, public?: true
    attribute :stage, :atom, public?: true, constraints: [one_of: [:draft, :live, :archived]]

    attribute :ocr_status, :atom,
      public?: true,
      constraints: [one_of: [:pending, :done, :failed]]

    # Kept as typed, so a row can hold `""`, which Is Empty counts as empty.
    attribute :note, :string, public?: true, constraints: [allow_empty?: true]
    attribute :memo, :string, public?: true
    # A list of values from a fixed set, which Has Any Of asks about.
    # Never `nil`, as a list usually is declared: Is Empty still finds the
    # rows holding nothing.
    attribute :topics, {:array, :atom},
      allow_nil?: false,
      public?: true,
      default: [],
      constraints: [items: [one_of: [:billing, :shipping, :returns]]]

    # A list with no fixed set, which the filter does not offer.
    attribute :tags, {:array, :string}, public?: true, default: []

    # An amount in a currency, compared by its amount within that currency.
    attribute :fee, :money,
      public?: true,
      constraints: [ex_money_opts: [default_currency: :USD, only: [:USD, :EUR]]]

    # With no default currency: a bare amount is in the reader's locale's.
    attribute :deposit, :money, public?: true

    # Ash takes it only in a filter's one top-level `==`, which a row of the
    # form need not be, so the filter does not offer it.
    attribute :reference, :string, public?: true, filterable?: :simple_equality
  end

  relationships do
    belongs_to :parent, __MODULE__, public?: true
    has_many :children, __MODULE__, destination_attribute: :parent_id
  end

  aggregates do
    # Never empty: a row with no children sums to its default.
    sum :children_salary, :children, :salary, default: 0, public?: true
  end
end

defmodule Example.Test.FilterFieldsLive.Quick do
  @moduledoc """
  The page over `Example.Test.FilterFields`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.FilterFields,
    # A column label of its own, which the filter's chip names the field by.
    list: [fields: [:code, {:stamped_at, label: "Stamped"}, :active]],
    details: [fields: [:code, :stamped_at]]
end

defmodule Example.Test.FilterFieldsNamedLive.Quick do
  @moduledoc """
  The page over `Example.Test.FilterFields` whose filter offers three fields,
  out of the resource's order: a stage, a code, and a salary only an admin may
  see. Routed only in the test build.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.FilterFields,
    list: [fields: [:code, :active], filterable: [:stage, :code, :salary]],
    details: [fields: [:code]]
end

defmodule Example.Test.FilterFieldsNoneLive.Quick do
  @moduledoc """
  The page over `Example.Test.FilterFields` whose list offers no filter.
  Routed only in the test build.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.FilterFields,
    list: [fields: [:code, :active], filterable: []],
    details: [fields: [:code]]
end

defmodule Example.Test.FilterFieldsSalaryLive.Quick do
  @moduledoc """
  The page over `Example.Test.FilterFields` whose filter offers only the
  salary, which only an admin may see: anyone else is offered no field.
  Routed only in the test build.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.FilterFields,
    list: [fields: [:code, :active], filterable: [:salary]],
    details: [fields: [:code]]
end
