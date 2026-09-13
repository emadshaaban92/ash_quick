defmodule AshQuick.Nav do
  @moduledoc """
  The host's navigation registry: one declaration the sidebar and the apps
  grid are both rendered from.

      defmodule MyAppWeb.Nav do
        use AshQuick.Nav,
          router: MyAppWeb.Router,
          access_control: MyAppWeb.AccessControl

        nav do
          entry "/scan", label: "Scan", icon: "hero-qr-code"
          entry "/profile", label: "My Profile", icon: "hero-user-circle-solid"

          group "Catalog", ~w(/products /brands /categories),
            icon: "hero-archive-box-solid"
        end
      end

      config :ash_quick, nav: MyAppWeb.Nav

  The two modules a nav is resolved against are declared on it, since it is
  the one place that has to know them: `:router` is what its QuickViews are
  discovered from, and `:access_control` is what every rendering of it filters
  through. Both are optional, and neither is called while the nav compiles —
  the router compiles the views the nav names, so reading it here would be a
  cycle. Both are written out as literal module names: a nav given a module
  attribute or an `Application.compile_env/3` call refuses to compile, since
  `Spark.Dsl` would otherwise drop the options and leave the nav unfiltered.

  ## What is declared and what is discovered

  Paths are not listed twice. `AshQuick.Nav.Info` walks the declared router
  for the base path every `AshQuick.LiveView.Router.quick_view/3` route
  carries, so every QuickView is already an entry, labelled from its resource
  and drawn with a default icon. A declaration only states what the router
  cannot: a better label, an icon, a group, or a path the router serves
  through something that is not a QuickView.

  Discovery is off the router rather than off the resources because the
  router is what serves the request. A path guessed from a resource can
  disagree with the route — and a resource with no route at all becomes a
  link to nowhere.

  With no router declared the registry is what the nav declares alone; with
  no declarations it is the discovered routes alone, ungrouped: a working
  sidebar with derived labels and default icons.

  ## Navigation is not authorization

  The registry says what exists, never who may see it. Every rendering
  filters through the declared `AshQuick.AccessControl`, and a group whose
  every path the viewer is denied does not render. With none declared,
  nothing is filtered. The two stay separate lists a human writes; what they
  can no longer do is silently disagree, since a declared path the router
  does not serve, and a granted route no entry covers, are both assertable.
  """

  use Spark.Dsl,
    default_extensions: [extensions: [AshQuick.Nav.Dsl]],
    opt_schema: [
      router: [
        type: :module,
        doc: "The `Phoenix.Router` the QuickViews this nav links to are discovered from."
      ],
      access_control: [
        type: :module,
        doc: """
        A module implementing `AshQuick.AccessControl`, filtering every
        rendering of this nav down to what a scope may navigate to.
        """
      ]
    ]

  # `Spark.Dsl` keeps the options it was given only if the whole list is a
  # quoted literal, and silently substitutes an empty one otherwise — so
  # `router: @router`, or any `Application.compile_env/3`, would leave both
  # modules unset and every rendering of the nav unfiltered, with nothing said.
  # A nav that quietly stops filtering is the one failure here worth refusing
  # to compile over, so the names have to be written out.
  defmacro __using__(opts) do
    unless Macro.quoted_literal?(opts) do
      raise ArgumentError, """
      `use #{inspect(__MODULE__)}` takes its options as literals, and these \
      are not:

          #{Macro.to_string(opts)}

      Write the module names out:

          use #{inspect(__MODULE__)},
            router: MyAppWeb.Router,
            access_control: MyAppWeb.AccessControl
      """
    end

    super(opts)
  end

  # Stored on the module rather than called: see the moduledoc on the cycle.
  @impl Spark.Dsl
  def handle_opts(opts) do
    quote do
      @persist {:router, unquote(opts[:router])}
      @persist {:access_control, unquote(opts[:access_control])}
    end
  end
end
