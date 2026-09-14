defmodule ExampleWeb.Nav do
  @moduledoc """
  Where every page appears in navigation.

  The sidebar and the apps grid are two renderings of this, filtered through
  `ExampleWeb.AccessControl` — a group with nothing reachable in it has no tile
  and no heading, so what a user is offered is what their role actually
  unlocks.

  Paths are not repeated from the router: `AshQuick.Nav.Info` finds every
  QuickView by walking `ExampleWeb.Router`, and each one's label comes from its
  resource's `plural_name`. An `entry` here states only what the router cannot
  — an icon, a label the resource gets wrong, or a page that is not a QuickView
  at all.
  """

  use AshQuick.Nav, router: ExampleWeb.Router, access_control: ExampleWeb.AccessControl

  nav do
    entry "/", label: "Home", icon: "hero-home-solid"

    entry "/brands", icon: "hero-rectangle-group-solid"
    entry "/categories", icon: "hero-rectangle-stack-solid"
    entry "/products", icon: "hero-cube-solid"
    entry "/price_changes", icon: "hero-banknotes-solid"

    entry "/users", icon: "hero-user-group-solid"
    # Not a QuickView, so there is no resource to derive a label from.
    entry "/browser_sessions", label: "Live Users", icon: "hero-users-solid"

    entry "/audit_logs", icon: "hero-eye-solid"
    entry "/file_objects", icon: "hero-photo-solid"

    # A tile links to the first path its viewer can reach, so the path a group
    # is most recognisable by comes first.
    group "Catalog", ~w(/products /categories /brands /price_changes),
      icon: "hero-archive-box-solid"

    group "Settings", ~w(/users /browser_sessions), icon: "hero-cog-8-tooth-solid"
    group "Audit", ~w(/audit_logs), icon: "hero-eye-solid"
    group "Uploads", ~w(/file_objects), icon: "hero-photo-solid"
  end
end
