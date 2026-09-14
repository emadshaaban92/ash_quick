defmodule AshQuick.Test.Gen.Unadopted do
  @moduledoc """
  A resource that never took the extension on, and has no field to name a record
  by either — what `mix ash_quick.gen.resource` is pointed at.
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
    attribute :code, :string, public?: true
  end
end
