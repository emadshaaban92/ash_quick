defmodule AshQuick.Test.Exposure.Domain do
  @moduledoc """
  Holds `AshQuick.Test.Exposure.Payslip`, the fixture for what a QuickView
  exposes: which of a resource's actions it can reach, and which of its fields
  it shows.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshQuick.Test.Exposure.Payslip do
  @moduledoc """
  A resource with internal actions and field policies, written the way Ash's
  documentation says to write both.

  Every action has a private twin of the same type, so a page that offers or
  runs one has nothing but `public?` to tell them apart. The private ones are
  let through by the `private_action?()` bypass Ash recommends for internal
  callers, which is what makes reaching one from a page a hole rather than an
  error: no policy refuses it.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Exposure.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :amount, :integer, public?: true
    attribute :owner_id, :uuid, public?: true
  end

  actions do
    defaults [:read, create: [:name, :amount, :owner_id]]

    read :index do
      argument :search, :string

      pagination do
        keyset? true
        offset? true
        default_limit 20
        countable :by_default
      end
    end

    read :payroll_export do
      public? false
    end

    create :import do
      public? false
      accept [:name, :amount, :owner_id]
    end

    update :update do
      accept [:name]
    end

    # Input-less, like `:destroy` and `:purge`, so the bulk menu would derive it.
    update :recompute do
      public? false
      accept []
    end

    destroy :destroy

    destroy :purge do
      public? false
    end
  end

  policies do
    bypass private_action?() do
      authorize_if always()
    end

    policy always() do
      authorize_if always()
    end
  end

  field_policies do
    # Hidden from everyone, whichever record it is read from.
    field_policy :amount do
      forbid_if always()
    end

    # Visible on the actor's own payslips only, so whether it shows depends on
    # the record.
    field_policy :owner_id do
      authorize_if expr(owner_id == ^actor(:id))
    end

    field_policy :* do
      authorize_if always()
    end
  end

  ash_quick do
    bookkeeping do
      inserted_at false
      updated_at false
      inserted_by false
      updated_by false
    end

    liveness do
      enabled? false
    end

    audit do
      enabled? false
    end
  end
end
