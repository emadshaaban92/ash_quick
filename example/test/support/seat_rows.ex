defmodule Example.Test.SeatRows.Seat do
  @moduledoc """
  A seat of `Example.Test.SeatRows`, keyed by `(seat_rows_id, seat)`. The
  parent's id is private, so a stored row's sub-form posts `:seat` alone:
  part of its key.
  """
  use Ash.Resource, domain: Example.Test.ManagedRows.Domain, data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:seat, :note, :secret]
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:note]
    end
  end

  attributes do
    attribute :seat, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :note, :string, public?: true
    attribute :secret, :string, public?: false
  end

  relationships do
    belongs_to :seat_rows, Example.Test.SeatRows,
      primary_key?: true,
      allow_nil?: false,
      attribute_public?: false
  end
end

defmodule Example.Test.SeatRows do
  @moduledoc """
  An update managing `has_many` rows whose primary key holds the parent's
  id, which their sub-forms do not post. In ETS, like
  `Example.Test.ManagedRows`.
  """
  use Ash.Resource,
    domain: Example.Test.ManagedRows.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:code]
      argument :seats, {:array, :map}, allow_nil?: true, default: []
      change manage_relationship(:seats, type: :create)
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:code]
      argument :seats, {:array, :map}, allow_nil?: true
      change manage_relationship(:seats, type: :direct_control)
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
  end

  relationships do
    has_many :seats, Example.Test.SeatRows.Seat, public?: true, sort: [seat: :asc]
  end
end

defmodule Example.Test.SeatRowsLive.Quick do
  @moduledoc """
  The page over `Example.Test.SeatRows`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.SeatRows,
    list: [fields: [:code]],
    details: [fields: [:code]]
end
