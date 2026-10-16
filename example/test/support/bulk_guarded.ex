defmodule Example.Test.BulkGuarded.Domain do
  @moduledoc "Holds the resource whose bulk menu and bulk runs disagree."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.BulkGuarded do
  @moduledoc """
  A resource whose bulk menu offers an action its run refuses, and a page over
  it that names no bulk actions, so the menu is derived.

  `:seal` is refused under `AshQuick.form_source/0` and nowhere else, so the
  menu, probed under `:ash_quick_list_bulk`, offers it while every run is
  refused: the case that shows which source a bulk run carries. `:stamp` is
  refused on a row coded "locked" alone, a rule only a row can answer.
  `:retire` is a destroy that takes an argument, which a derived menu leaves
  out.

  In ETS rather than Postgres: nothing here is about what lands in a table.
  """
  use Ash.Resource,
    domain: Example.Test.BulkGuarded.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  actions do
    defaults [:read, :destroy, create: [:code]]

    read :index do
      argument :search, :string

      pagination do
        keyset? true
        offset? true
        default_limit 20
        countable :by_default
      end
    end

    update :seal do
      accept []
      change set_attribute(:sealed, true)
    end

    update :stamp do
      accept []
      change set_attribute(:stamped, true)
    end

    destroy :retire do
      argument :reason, :string, allow_nil?: false
    end
  end

  policies do
    policy action(:seal) do
      forbid_if context_equals(:action_source, :ash_quick_form)
      authorize_if always()
    end

    # A rule only a row can answer, so a probe of no row says no; the menu's
    # probe is let through, as a host whose rows decide it would.
    policy action(:stamp) do
      authorize_if context_equals(:action_source, :ash_quick_list_bulk)
      authorize_if expr(code != "locked")
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
    attribute :stamped, :boolean, allow_nil?: false, default: false, public?: true
  end
end

defmodule Example.Test.BulkGuardedLive.Quick do
  @moduledoc """
  The page over `Example.Test.BulkGuarded`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.BulkGuarded,
    list: [fields: [:code, :sealed]],
    details: [fields: [:code, :sealed]]
end

defmodule Example.Test.BulkNamedLive.Quick do
  @moduledoc """
  A second page over `Example.Test.BulkGuarded`, naming its bulk menu as a
  list: one derived action, and a custom item, so the derived `:seal` it
  leaves out is absent.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.BulkGuarded,
    list: [
      fields: [:code, :sealed],
      bulk_actions: [:destroy, %{title: "Count them", func: Phoenix.LiveView.JS.push("count")}]
    ],
    details: [fields: [:code, :sealed]]
end
