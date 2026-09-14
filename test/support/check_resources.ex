defmodule AshQuick.Test.Check.Bare do
  @moduledoc """
  A resource with no AshQuick extension at all — the one every verifier is blind
  to, and the whole reason the compliance check exists.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Check.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  actions do
    defaults [:read, :create]
  end
end

defmodule AshQuick.Test.Check.Widget do
  @moduledoc """
  The resource behind the fixture QuickView.

  `:rename` takes an input, so its button patches to `/:id/rename` rather than
  running inline — which is what the router below is missing a route for.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Check.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  actions do
    default_accept [:name]
    defaults [:read, :create, :destroy]

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
      accept [:name]
    end
  end

  ash_quick do
    display do
      label :name
    end

    liveness do
      enabled? false
    end

    versioning do
      enabled? false
    end

    audit do
      enabled? false
    end

    bookkeeping do
      created_at false
      updated_at false
      created_by false
      updated_by false
    end
  end
end

defmodule AshQuick.Test.Check.Gizmo do
  @moduledoc """
  Listed and nothing else: its QuickView is routed `only: [:index]`, so every
  row's details link leads to a route that is not there.

  No `:create` and no input-taking update, so the list's other two controls have
  nothing to say about it.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Check.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  actions do
    defaults [:read]

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
      label :name
    end

    liveness do
      enabled? false
    end

    versioning do
      enabled? false
    end

    audit do
      enabled? false
    end

    bookkeeping do
      created_at false
      updated_at false
      created_by false
      updated_by false
    end
  end
end

defmodule AshQuick.Test.Check.Echo do
  @moduledoc """
  Publishes on "signal", as does `AshQuick.Test.Check.Repeat`.

  Liveness stays *enabled* on both: a resource that publishes nothing collides
  with nothing, so the collision only exists between two that do.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Check.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  ash_quick do
    display do
      label :name
    end

    liveness do
      prefix "signal"
    end

    versioning do
      enabled? false
    end

    audit do
      enabled? false
    end

    bookkeeping do
      created_at false
      updated_at false
      created_by false
      updated_by false
    end
  end
end

defmodule AshQuick.Test.Check.Repeat do
  @moduledoc "The other half of the prefix collision. See `AshQuick.Test.Check.Echo`."
  use Ash.Resource,
    domain: AshQuick.Test.Check.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  actions do
    defaults [:read]
  end

  ash_quick do
    display do
      label :name
    end

    liveness do
      prefix "signal"
    end

    versioning do
      enabled? false
    end

    audit do
      enabled? false
    end

    bookkeeping do
      created_at false
      updated_at false
      created_by false
      updated_by false
    end
  end
end

defmodule AshQuick.Test.Check.Domain do
  @moduledoc """
  Registers its resources rather than allowing unregistered ones: the resource
  checks read `Ash.Domain.Info.resources/1`, which is empty for a domain that
  only tolerates them.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshQuick.Test.Check.Bare
    resource AshQuick.Test.Check.Widget
    resource AshQuick.Test.Check.Gizmo
    resource AshQuick.Test.Check.Echo
    resource AshQuick.Test.Check.Repeat
  end
end

defmodule AshQuick.Test.Check.WidgetLive.Quick do
  @moduledoc false
  use AshQuick.LiveView.QuickView, resource: AshQuick.Test.Check.Widget
end

defmodule AshQuick.Test.Check.GizmoLive.Quick do
  @moduledoc false
  use AshQuick.LiveView.QuickView, resource: AshQuick.Test.Check.Gizmo
end

defmodule AshQuick.Test.Check.PlainLive do
  @moduledoc "A LiveView that is not a QuickView, routed as though it were."
  use Phoenix.LiveView

  @impl true
  def render(assigns), do: ~H"<div>plain</div>"
end

defmodule AshQuick.Test.Check.Router do
  @moduledoc """
  One of each way a router can be wrong about a QuickView, alongside one that is
  right.
  """
  use Phoenix.Router

  import AshQuick.LiveView.Router
  import Phoenix.LiveView.Router, only: [live: 3, live: 4]

  # Right, except that `:rename` has nowhere to patch to.
  quick_view("/widgets", AshQuick.Test.Check.WidgetLive.Quick, only: [:index, :show])

  # A list whose rows link to a details page that is not served.
  quick_view("/gizmos", AshQuick.Test.Check.GizmoLive.Quick, only: [:index])

  # A QuickView with no base path to read.
  live("/hand_routed", AshQuick.Test.Check.WidgetLive.Quick, nil)

  # A base path on something that cannot read one.
  live("/plain", AshQuick.Test.Check.PlainLive, :index,
    metadata: %{ash_quick: %{base_path: "/plain"}}
  )

  # A QuickView carrying a base path it is not served under, which only a
  # hand-written metadata can produce — `quick_view/3` takes the scope prefix
  # into account.
  live("/elsewhere", AshQuick.Test.Check.WidgetLive.Quick, nil,
    metadata: %{ash_quick: %{base_path: "/widgets"}}
  )

  # Served, and in neither the nav nor a group.
  live("/orphan", AshQuick.Test.Check.PlainLive, :orphan)
end

defmodule AshQuick.Test.Check.AccessControl do
  @moduledoc """
  Grants one route the router serves and the nav renders, one it renders without
  a tile, and one that is gone.
  """
  @behaviour AshQuick.AccessControl

  @impl true
  def routes_for(_scope), do: all_routes()

  @impl true
  def all_routes, do: ~w(/widgets /plain /orphan /gone)
end

defmodule AshQuick.Test.Check.SilentAccessControl do
  @moduledoc "An access control that cannot enumerate what it grants."
  @behaviour AshQuick.AccessControl

  @impl true
  def routes_for(_scope), do: ["/widgets"]
end

defmodule AshQuick.Test.Check.Nav do
  @moduledoc false
  use AshQuick.Nav,
    router: AshQuick.Test.Check.Router,
    access_control: AshQuick.Test.Check.AccessControl

  nav do
    entry("/widgets")
    entry("/plain", label: "Plain")
    entry("/missing", label: "Missing")

    group("Things", ~w(/widgets))
  end
end

defmodule AshQuick.Test.Check.Unadopted do
  @moduledoc """
  A second un-adopted resource, in a domain of its own.

  It exists so that a run can produce advisories and nothing else — which is the
  only way to watch `--strict` decline to fail on them.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Check.AdvisoryDomain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  actions do
    defaults [:read, :create]
  end
end

defmodule AshQuick.Test.Check.AdvisoryDomain do
  @moduledoc "Holds `AshQuick.Test.Check.Unadopted` and nothing else."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshQuick.Test.Check.Unadopted
  end
end
