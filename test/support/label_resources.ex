defmodule AshQuick.Test.Labels.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshQuick.Test.Labels.Status do
  @moduledoc "An enum with labels of its own, one of which the loan rewords."
  use Ash.Type.Enum, values: [active: "Active", paid_off: "Paid off", cancelled: "Cancelled"]
end

defmodule AshQuick.Test.Labels.Borrower do
  @moduledoc "Who a loan is to, labelling a field of its own."
  use Ash.Resource,
    domain: AshQuick.Test.Labels.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :national_id, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  ash_quick do
    labels do
      label(:national_id, "National ID")
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
  end
end

defmodule AshQuick.Test.Labels.Loan do
  @moduledoc """
  A resource declaring a label for each kind of thing it names: an
  attribute, a relationship, an action, an action's argument, a value of an
  `Ash.Type.Enum` and a value of an atom's `one_of`.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Labels.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :borrower_national_id, :string, public?: true
    attribute :status, AshQuick.Test.Labels.Status, public?: true
    attribute :kind, :atom, public?: true, constraints: [one_of: [:personal, :business]]
  end

  relationships do
    belongs_to :borrower, AshQuick.Test.Labels.Borrower, public?: true
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:name, :borrower_national_id, :status, :kind]
    end

    update :issue_bill_of_sale do
      accept []
      require_atomic? false
      argument :reason_code, :string
    end
  end

  ash_quick do
    labels do
      label(:borrower_national_id, "Borrower National ID")
      label(:borrower, "Applicant")
      label(:issue_bill_of_sale, "Issue Bill of Sale")
      label(:reason_code, "Reason")
      label(:status, :paid_off, "Paid Off in Full")
      label(:kind, :business, "Business Loan")
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
  end
end
