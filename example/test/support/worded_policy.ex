defmodule Example.Test.WordedPolicy.Domain do
  @moduledoc "Holds the resource whose policies say why they refuse."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.WordedPolicy do
  @moduledoc """
  A resource whose policies carry an `error_message`, and a page over it.

  `:rename` refuses one value only, "locked", which only the submitted input
  can answer: the modal opens, and the run refuses in the policy's words.
  `:seal` is refused under `AshQuick.form_source/0`, so the bulk menu (probed
  under `:ash_quick_list_bulk`) offers it and the run refuses, again in the
  policy's words. `:stamp` refuses the same way with no message of its own, the
  control that still gets the fixed sentence.

  In ETS rather than Postgres: nothing here is about what lands in a table.
  """
  use Ash.Resource,
    domain: Example.Test.WordedPolicy.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  actions do
    defaults [:read, create: [:code]]

    read :index do
      argument :search, :string

      pagination do
        keyset? true
        offset? true
        default_limit 20
        countable :by_default
      end
    end

    update :rename do
      accept [:code]
    end

    update :seal do
      accept []
      change set_attribute(:sealed, true)
    end

    update :stamp do
      accept []
      change set_attribute(:sealed, true)
    end
  end

  policies do
    policy action(:rename) do
      forbid_if changing_attributes(code: [to: "locked"])
      authorize_if always()
      error_message "No record may be renamed to locked."
    end

    policy action(:seal) do
      forbid_if context_equals(:action_source, :ash_quick_form)
      authorize_if always()
      error_message "Sealing is closed for the season."
    end

    policy action(:stamp) do
      forbid_if context_equals(:action_source, :ash_quick_form)
      authorize_if always()
    end

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
    attribute :sealed, :boolean, allow_nil?: false, default: false, public?: true
  end
end

defmodule Example.Test.WordedPolicyLive.Quick do
  @moduledoc """
  The page over `Example.Test.WordedPolicy`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.WordedPolicy,
    list: [fields: [:code, :sealed]],
    details: [fields: [:code, :sealed]]
end
