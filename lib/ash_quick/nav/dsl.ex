defmodule AshQuick.Nav.Dsl do
  @moduledoc false
  # The `nav do ... end` DSL. See `AshQuick.Nav` for what it is for.

  @icon_type {:or, [:string, {:fun, 1}, {:tuple, [:atom, :atom]}]}
  @icon_doc """
  A heroicon class name (`"hero-cube-solid"`), a `{module, function}` naming a
  function component, or a one-argument function. The two component forms
  receive a `:class` assign and may render anything — an inline `<svg>`, an
  `<img>`, a sprite. `{module, function}` is the form a verifier can check
  exists, so prefer it over an anonymous function.
  """

  @entry %Spark.Dsl.Entity{
    name: :entry,
    describe: """
    Declares a nav entry, or fills in one the router already serves.

    Only what cannot be discovered is stated: a QuickView's label comes from
    its resource and its icon from a default, so an entry for one is needed
    only to override those. A path the router serves through anything else
    has to be declared here to appear at all.
    """,
    examples: [
      ~s|entry "/scan", label: "Scan", icon: "hero-qr-code"|,
      ~s|entry "/profile", label: "My Profile"|
    ],
    args: [:path],
    target: AshQuick.Nav.Entry,
    schema: [
      path: [
        type: :string,
        required: true,
        doc: "The path the entry navigates to, exactly as the router serves it."
      ],
      label: [
        type: :string,
        doc: "What to call it. Derived from the resource or the path when omitted."
      ],
      icon: [type: @icon_type, doc: @icon_doc]
    ]
  }

  @group %Spark.Dsl.Entity{
    name: :group,
    describe: """
    Groups paths under a heading. Renders as a sidebar section and as one grid
    tile linking to the first path in the list the viewer can reach.

    The same path may be named by several groups.
    """,
    examples: [
      ~s|group "Catalog", ~w(/products /brands), icon: "hero-archive-box-solid"|
    ],
    args: [:label, :paths],
    target: AshQuick.Nav.Group,
    schema: [
      label: [type: :string, required: true, doc: "The heading, and the tile's label."],
      paths: [
        type: {:list, :string},
        required: true,
        doc: "Paths in the group, most representative first — the tile links to the first one."
      ],
      icon: [type: @icon_type, doc: @icon_doc]
    ]
  }

  @nav %Spark.Dsl.Section{
    name: :nav,
    describe: """
    What the router cannot say about navigation: labels, icons, ordering,
    grouping, and the entries that are not QuickViews.
    """,
    entities: [@entry, @group]
  }

  use Spark.Dsl.Extension, sections: [@nav], verifiers: [AshQuick.Nav.Verifier]
end
