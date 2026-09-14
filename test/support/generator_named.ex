defmodule AshQuick.Test.Gen.Named do
  @moduledoc """
  Unadopted, but already named — so the extension has a label to work from.
  """
  use Ash.Resource, domain: AshQuick.Test.Gen.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  actions do
    defaults [:read, :create]
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
    attribute :created_at, :utc_datetime_usec, public?: true
  end
end
