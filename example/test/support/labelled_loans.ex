defmodule Example.Test.LabelledLoans.Domain do
  @moduledoc "Holds the resources behind a page whose labels the resource declares."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.LabelledLoans.Status do
  @moduledoc "An enum with labels of its own, one of which the loan rewords."
  use Ash.Type.Enum, values: [active: "Active", paid_off: "Paid off"]
end

defmodule Example.Test.LabelledLoans.Borrower do
  @moduledoc """
  Who a loan is to, one hop from the page, labelling a field of its own.
  Carries the extension because the loan's create form offers a dropdown onto
  it.
  """
  use Ash.Resource,
    domain: Example.Test.LabelledLoans.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, create: [:name, :national_id]]

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
    labels do
      label(:national_id, "National ID")
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
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :national_id, :string, public?: true
  end
end

defmodule Example.Test.LabelledLoans do
  @moduledoc """
  A loan whose resource labels a field, a relationship, two actions, an
  argument, a value of an `Ash.Type.Enum` and a value of an atom's `one_of`,
  and a page over it that draws each of them. `:reference_no` is no column,
  so the filter names it as the resource does.

  In ETS rather than Postgres: nothing here is about what lands in a table.
  """
  use Ash.Resource,
    domain: Example.Test.LabelledLoans.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :borrower_national_id, :reference_no, :status, :kind, :borrower_id]
    end

    update :issue_bill_of_sale do
      accept []
      require_atomic? false
      argument :reason_code, :string, allow_nil?: false
    end

    update :close_out do
      accept []
      require_atomic? false
      change set_attribute(:status, :paid_off)
    end

    read :index do
      argument :search, :string

      pagination do
        keyset? true
        offset? true
        default_limit 20
        countable :by_default
      end
    end
  end

  ash_quick do
    labels do
      label(:borrower_national_id, "Borrower National ID")
      label(:reference_no, "Loan Reference")
      label(:borrower, "Applicant")
      label(:issue_bill_of_sale, "Issue Bill of Sale")
      label(:close_out, "Settle Early")
      label(:reason_code, "Reason")
      label(:status, :paid_off, "Paid Off in Full")
      label(:kind, :business, "Business Loan")
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
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :borrower_national_id, :string, public?: true
    attribute :reference_no, :string, public?: true
    attribute :status, Example.Test.LabelledLoans.Status, public?: true, default: :active
    attribute :kind, :atom, public?: true, constraints: [one_of: [:personal, :business]]
  end

  relationships do
    belongs_to :borrower, Example.Test.LabelledLoans.Borrower, public?: true
  end
end

defmodule Example.Test.LabelledLoansLive.Quick do
  @moduledoc """
  The page over `Example.Test.LabelledLoans`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`. Its fields carry no
  `label:` but one, so every other label on the page is the resource's.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.LabelledLoans,
    list: [
      fields: [:name, :borrower_national_id, :status, :kind, [borrower: :national_id]],
      bulk_actions: [:close_out]
    ],
    details: [
      fields: [
        :borrower_national_id,
        :status,
        [borrower: :national_id],
        {:kind, label: "Loan Type"}
      ]
    ]
end
