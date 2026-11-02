defmodule AshQuick.Test.LocalDatetime.Domain do
  @moduledoc """
  Holds the fixtures below, which are never read: only the params a form over
  them would post are converted.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshQuick.Test.LocalDatetime.Stamp do
  @moduledoc "An embedded instant, drawn as a sub-form of `Event`'s."
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :at, :utc_datetime, public?: true
    attribute :label, :string, public?: true
  end
end

defmodule AshQuick.Test.LocalDatetime.Event do
  @moduledoc """
  Takes an instant of each kind a form types into a `datetime-local` input: an
  accepted attribute, an argument, and one in each sub-form; beside a date and
  a string, which are none.
  """
  use Ash.Resource,
    domain: AshQuick.Test.LocalDatetime.Domain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
    attribute :starts_at, :utc_datetime_usec, public?: true
    attribute :on_day, :date, public?: true
    attribute :stamps, {:array, AshQuick.Test.LocalDatetime.Stamp}, public?: true
  end

  actions do
    defaults [:read]

    create :create do
      accept [:title, :starts_at, :on_day, :stamps]
      argument :remind_at, :datetime
    end

    update :update do
      accept [:starts_at]
      argument :remind_at, :datetime
    end
  end
end
