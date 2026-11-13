defmodule Example.Test.ProbedDestroys.Domain do
  @moduledoc "Holds the resource whose destroy validations say what they saw."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.ProbedDestroys.Seen do
  @moduledoc """
  Tells the calling process what a validation saw, as
  `{:validated, name, probe?, id}`: `name` says which validation ran, `probe?`
  is `AshQuick.probe?/1` over the changeset and over the validation's context,
  and `id` is the id of the record the changeset was built over.

  With `guard?: true` it returns `:ok` for a probe before it looks at the
  record, the way a host guards a validation that queries by the record's id.
  Otherwise it refuses a record with no id, as a validation that queries by
  `changeset.data.id` would go wrong over one.
  """
  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, opts, context) do
    probe? = {AshQuick.probe?(changeset), AshQuick.probe?(context)}
    send(self(), {:validated, opts[:name], probe?, changeset.data.id})

    cond do
      opts[:guard?] && AshQuick.probe?(changeset) -> :ok
      is_nil(changeset.data.id) -> {:error, field: :id, message: "has no record"}
      true -> :ok
    end
  end
end

defmodule Example.Test.ProbedDestroys do
  @moduledoc """
  A resource whose destroys run validations that report what they saw, so a
  test can tell a QuickView probe from a run.

  `:destroy` runs an unguarded validation and a guarded one when the changeset
  is built; `:discard` runs one in a `before_action` hook (`before_action?:
  true`), which only a run reaches.

  In ETS rather than Postgres: nothing here is about what lands in a table.
  """
  use Ash.Resource,
    domain: Example.Test.ProbedDestroys.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  alias Example.Test.ProbedDestroys.Seen

  actions do
    defaults [:read, create: [:code]]

    destroy :destroy do
      primary? true
      require_atomic? false
      validate {Seen, name: :unguarded}
      validate {Seen, name: :guarded, guard?: true}
    end

    destroy :discard do
      require_atomic? false
      validate {Seen, name: :deferred}, before_action?: true
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
end
