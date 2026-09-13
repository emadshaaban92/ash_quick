defmodule AshQuick.Test.Nav.Domain do
  @moduledoc """
  Holds the resource the fixture QuickView renders. Nothing here is read — nav
  resolution only ever introspects.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshQuick.Test.Nav.Brand do
  @moduledoc """
  The resource behind the fixture QuickView.

  It exists for its `plural_name`: an entry nothing declares is labelled from
  the resource the route discovers, so "Brands" has to come from somewhere
  other than the path for that derivation to be worth asserting.
  """
  use Ash.Resource,
    domain: AshQuick.Test.Nav.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  ets do
    private? true
  end

  resource do
    plural_name :brands
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  actions do
    default_accept [:name]
    defaults [:read, :create, :update, :destroy]

    # The searchable read every QuickView is required to reach through.
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

    bookkeeping do
      created_at false
      updated_at false
      created_by false
      updated_by false
    end
  end
end

defmodule AshQuick.Test.Nav.BrandLive.Quick do
  @moduledoc """
  A QuickView, which is what the router discovers a resource through.

  Discovery reads `__ash_quick_options__/0` off the route's view, so a plain
  module naming the resource would not do — the route has to point at something
  that really went through `use AshQuick.LiveView.QuickView`.
  """
  use AshQuick.LiveView.QuickView, resource: AshQuick.Test.Nav.Brand
end

defmodule AshQuick.Test.Nav.ScanLive.Index do
  @moduledoc """
  A plain LiveView reached through `live/3`.

  The other half of what discovery turns on: a route with no `ash_quick`
  metadata, which a nav can still declare an entry for but cannot derive a
  resource or a label from.
  """
  use Phoenix.LiveView

  @impl true
  def render(assigns), do: ~H"<div>scan</div>"
end

defmodule AshQuick.Test.Nav.Router do
  @moduledoc """
  A router holding one QuickView and one plain LiveView, which is the
  difference nav discovery turns on.
  """
  use Phoenix.Router

  import AshQuick.LiveView.Router
  import Phoenix.LiveView.Router, only: [live: 3]

  quick_view("/brands", AshQuick.Test.Nav.BrandLive.Quick)
  live("/scan", AshQuick.Test.Nav.ScanLive.Index, :index)
end

defmodule AshQuick.Test.Nav.Scope do
  @moduledoc """
  What a host hands the nav to be filtered against.

  AshQuick never looks inside it — `AshQuick.AccessControl` is the only thing
  that reads a scope — so the fixture carries nothing but the roles the fixture
  access control decides on.
  """
  defstruct roles: []
end

defmodule AshQuick.Test.Nav.AccessControl do
  @moduledoc """
  The host's answer to "where may this scope go".

  Two roles rather than one, and deliberately not nested: `:catalog` holds a
  strict subset of `:admin`, so a filter that dropped the access control
  entirely would still satisfy `:admin` and only `:catalog` catches it.
  """
  @behaviour AshQuick.AccessControl

  @impl true
  def routes_for(%AshQuick.Test.Nav.Scope{roles: roles}) do
    roles |> Enum.flat_map(&routes_for_role/1) |> Enum.uniq()
  end

  defp routes_for_role(:admin), do: ["/brands", "/scan", "/products"]
  defp routes_for_role(:catalog), do: ["/brands", "/products"]
  defp routes_for_role(_role), do: []
end

defmodule AshQuick.Test.Nav.Icons do
  @moduledoc "An icon the host draws itself, rather than naming a heroicon."
  use Phoenix.Component

  def brand(assigns) do
    ~H"""
    <svg class={@class} data-testid="hand-drawn"><circle r="1" /></svg>
    """
  end
end

defmodule AshQuick.Test.Nav.Declared do
  @moduledoc "A nav declaring both a router and an access control."
  use AshQuick.Nav,
    router: AshQuick.Test.Nav.Router,
    access_control: AshQuick.Test.Nav.AccessControl

  nav do
    entry("/scan", icon: "hero-qr-code")
    entry("/brands", label: "Marques", icon: {AshQuick.Test.Nav.Icons, :brand})
    entry("/products")

    group("Things", ~w(/brands /scan), icon: "hero-cube-solid")
    group("Also Brands", ~w(/brands))
  end
end

defmodule AshQuick.Test.Nav.Bare do
  @moduledoc "A nav declaring neither a router nor an access control."
  use AshQuick.Nav

  nav do
    entry("/anything", label: "Anything")
  end
end
