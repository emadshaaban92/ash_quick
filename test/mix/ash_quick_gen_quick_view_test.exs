defmodule Mix.Tasks.AshQuick.Gen.QuickViewTest do
  @moduledoc """
  The generator, against real resources.

  The field list and the route shape are both read off a compiled resource, so
  the fixtures in `test/support/generator_resources.ex` are the input rather
  than source in the test project: what the generator writes is a fact about
  the resource, and asserting it against a resource that only exists as text
  would be asserting against a parser.
  """
  use ExUnit.Case, async: true

  import Igniter.Test

  @quick "lib/test_web/widget_live/quick.ex"

  # What `import_deps: [:ash_quick]` gives a real host. Spelled out because the
  # harness cannot resolve the package's `.formatter.exs` through a project that
  # only exists in memory, and a router full of `quick_view(...)` is not what an
  # adopter's formatter would leave behind.
  @formatter """
  [
    inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
    locals_without_parens: [quick_view: 2, quick_view: 3, live: 2, live: 3]
  ]
  """

  @web_module """
  defmodule TestWeb do
    def router do
      quote do
        use Phoenix.Router
      end
    end
  end
  """

  @router """
  defmodule TestWeb.Router do
    use TestWeb, :router

    import AshQuick.LiveView.Router

    scope "/", TestWeb do
      live_session :authenticated, on_mount: [AshQuick.LiveView.Mount] do
        live "/", HomeLive, :index
      end
    end
  end
  """

  @access_control """
  defmodule TestWeb.AccessControl do
    @behaviour AshQuick.AccessControl

    @routes []

    @impl AshQuick.AccessControl
    def routes_for(_scope), do: @routes

    @impl AshQuick.AccessControl
    def all_routes, do: @routes
  end
  """

  @per_role_access_control """
  defmodule TestWeb.AccessControl do
    @behaviour AshQuick.AccessControl

    def routes_for_role(:admin), do: ~w(/users)
    def routes_for_role(:member), do: ["/products"]
    def routes_for_role(:owner), do: @common ++ ~w(/billing)
    def routes_for_role(_role), do: []

    @impl AshQuick.AccessControl
    def routes_for(scope), do: routes_for_role(scope.role)
  end
  """

  defp generate(argv, extra \\ %{}) do
    test_project(
      files:
        Map.merge(
          %{
            ".formatter.exs" => @formatter,
            "lib/test_web.ex" => @web_module,
            "lib/test_web/router.ex" => @router,
            "lib/test_web/access_control.ex" => @access_control
          },
          extra
        )
    )
    |> Igniter.compose_task("ash_quick.gen.quick_view", argv)
  end

  defp widget(extra \\ %{}), do: generate(["AshQuick.Test.Gen.Widget"], extra)

  describe "the module" do
    test "is named for the resource and declares it" do
      source = created(widget(), @quick)

      assert source =~ "defmodule TestWeb.WidgetLive.Quick do"
      assert source =~ "use AshQuick.LiveView.QuickView,"
      assert source =~ "resource: AshQuick.Test.Gen.Widget"
    end

    # The columns the resource is about, not the ones AshQuick added to it: a
    # generated page opening on `version` and two actor ids is one nobody reads.
    test "the starter fields are the resource's own, without the generated ones" do
      source = created(widget(), @quick)

      assert source =~ "fields: [:sku, :name]"
      assert source =~ "fields: [:sku, :name, :inserted_at, :updated_at]"

      refute source =~ ":version"
      refute source =~ ":inserted_by_id"
    end

    test "a sensitive attribute is not put on a page by a generator" do
      refute created(widget(), @quick) =~ ":secret"
    end

    test "neither is one the resource kept private" do
      refute created(widget(), @quick) =~ ":internal"
    end

    test "takes an explicit module name" do
      igniter =
        generate(["AshQuick.Test.Gen.Widget", "--module", "TestWeb.Admin.WidgetLive.Quick"])

      assert_creates(igniter, "lib/test_web/admin/widget_live/quick.ex")
    end

    test "leaves a module that is already there alone" do
      igniter =
        widget(%{
          @quick => """
          defmodule TestWeb.WidgetLive.Quick do
            @moduledoc "Ours."
          end
          """
        })

      assert_unchanged(igniter, @quick)
      assert_has_warning(igniter, &(&1 =~ "already exists"))
    end
  end

  # Custom `action_<name>.html.heex` templates apply to every QuickView in the
  # directory they sit in, so where the file lands decides which templates the
  # view picks up. A host's QuickViews already say where they go.
  describe "the file" do
    @nested_router """
    defmodule TestWeb.Router do
      use TestWeb, :router

      import AshQuick.LiveView.Router

      scope "/", TestWeb do
        live_session :authenticated, on_mount: [AshQuick.LiveView.Mount] do
          quick_view "/things", ThingLive.Quick
          quick_view "/ledger_entries", Ledgers.Quick
        end
      end
    end
    """

    defp quick_source(module, resource) do
      """
      defmodule #{module} do
        use AshQuick.LiveView.QuickView,
          resource: #{resource},
          fields: [:name]
      end
      """
    end

    test "goes where the QuickViews already routed are, in a directory of its own" do
      igniter =
        widget(%{
          "lib/test_web/router.ex" => @nested_router,
          "lib/test_web/live/things/thing_quick.ex" =>
            quick_source("TestWeb.ThingLive.Quick", "MyApp.Catalog.Thing"),
          "lib/test_web/live/ledger_entries/ledger_entry_quick.ex" =>
            quick_source("TestWeb.Ledgers.Quick", "MyApp.Books.LedgerEntry")
        })

      assert_written(igniter, "lib/test_web/live/widgets/widget_quick.ex")
      refute_written(igniter, @quick)

      assert created(igniter, "lib/test_web/live/widgets/widget_quick.ex") =~
               "defmodule TestWeb.WidgetLive.Quick do"
    end

    test "follows them for an explicit module name too" do
      igniter =
        generate(["AshQuick.Test.Gen.Widget", "--module", "TestWeb.Admin.WidgetsQuick"], %{
          "lib/test_web/router.ex" => @nested_router,
          "lib/test_web/live/things/thing_quick.ex" =>
            quick_source("TestWeb.ThingLive.Quick", "MyApp.Catalog.Thing")
        })

      assert_written(igniter, "lib/test_web/live/widgets/widget_quick.ex")
    end

    # The resource is read off the view's own `use` line, and the plural off
    # its route, so a view named for neither still tells where views go.
    test "reads the pattern off the resource and the route, not the module name" do
      igniter =
        widget(%{
          "lib/test_web/router.ex" => @nested_router,
          "lib/test_web/live/ledger_entries/ledger_entry_quick.ex" =>
            quick_source("TestWeb.Ledgers.Quick", "LedgerEntry")
        })

      assert_written(igniter, "lib/test_web/live/widgets/widget_quick.ex")
    end

    # The route may be named for something other than the resource; the
    # directory is still the resource's plural.
    test "reads the resource's own plural before the route's" do
      igniter =
        widget(%{
          "lib/test_web/router.ex" =>
            String.replace(@nested_router, ~s|"/ledger_entries"|, ~s|"/entries"|),
          "lib/test_web/live/ledger_entries/ledger_entry_quick.ex" =>
            quick_source("TestWeb.Ledgers.Quick", "MyApp.Books.LedgerEntry")
        })

      assert_written(igniter, "lib/test_web/live/widgets/widget_quick.ex")
    end

    test "a view routed at its scope's own path is read by its resource" do
      igniter =
        widget(%{
          "lib/test_web/router.ex" => """
          defmodule TestWeb.Router do
            use TestWeb, :router

            import AshQuick.LiveView.Router

            scope "/things", TestWeb do
              live_session :authenticated, on_mount: [AshQuick.LiveView.Mount] do
                quick_view "/", ThingLive.Quick
              end
            end
          end
          """,
          "lib/test_web/live/things/thing_quick.ex" =>
            quick_source("TestWeb.ThingLive.Quick", "MyApp.Catalog.Thing")
        })

      assert_written(igniter, "lib/test_web/live/widgets/widget_quick.ex")

      at_root =
        generate(["AshQuick.Test.Gen.Widget", "--path", "/"], %{
          "lib/test_web/router.ex" => @nested_router,
          "lib/test_web/live/things/thing_quick.ex" =>
            quick_source("TestWeb.ThingLive.Quick", "MyApp.Catalog.Thing")
        })

      assert_written(at_root, "lib/test_web/live/widgets/widget_quick.ex")
    end

    test "a view at its scope's own path that does not name its resource says nothing" do
      igniter =
        widget(%{
          "lib/test_web/router.ex" => """
          defmodule TestWeb.Router do
            use TestWeb, :router

            import AshQuick.LiveView.Router

            scope "/things", TestWeb do
              live_session :authenticated, on_mount: [AshQuick.LiveView.Mount] do
                quick_view "/", ThingLive.Quick
              end
            end
          end
          """,
          "lib/test_web/live/things/thing_quick.ex" => """
          defmodule TestWeb.ThingLive.Quick do
            @resource MyApp.Catalog.Thing

            use AshQuick.LiveView.QuickView, resource: @resource, fields: [:name]
          end
          """
        })

      assert_written(igniter, @quick)
    end

    test "names the file for the singular when a resource's two are one word" do
      igniter =
        widget(%{
          "lib/test_web/router.ex" => String.replace(@nested_router, ~s|"/things"|, ~s|"/news"|),
          "lib/test_web/live/news/news_quick.ex" =>
            quick_source("TestWeb.ThingLive.Quick", "MyApp.Feed.News")
        })

      assert_written(igniter, "lib/test_web/live/widgets/widget_quick.ex")
    end

    test "still gets a directory of its own when the existing views share one" do
      igniter =
        widget(%{
          "lib/test_web/router.ex" => @nested_router,
          "lib/test_web/live/thing_quick.ex" =>
            quick_source("TestWeb.ThingLive.Quick", "MyApp.Catalog.Thing")
        })

      assert_written(igniter, "lib/test_web/live/widgets/widget_quick.ex")
    end

    test "stays where Igniter puts it when that is where the others are" do
      igniter =
        widget(%{
          "lib/test_web/router.ex" => @nested_router,
          "lib/test_web/thing_live/quick.ex" =>
            quick_source("TestWeb.ThingLive.Quick", "MyApp.Catalog.Thing")
        })

      assert_written(igniter, @quick)
    end

    test "does not follow the QuickViews only a test routes" do
      igniter =
        widget(%{
          "lib/test_web/router.ex" => @nested_router,
          "lib/test_web/live/things/thing_quick.ex" =>
            quick_source("TestWeb.ThingLive.Quick", "MyApp.Catalog.Thing"),
          "test/support/ledger_entries.ex" =>
            quick_source("TestWeb.Ledgers.Quick", "MyApp.Books.LedgerEntry")
        })

      assert_written(igniter, "lib/test_web/live/widgets/widget_quick.ex")
    end

    # A second view over the same resource lands on the first one's file; the
    # route and the grant are not written for a module that is not.
    test "refuses a file that is already there" do
      igniter =
        generate(["AshQuick.Test.Gen.Widget", "--module", "TestWeb.WidgetArchiveLive.Quick"], %{
          "lib/test_web/router.ex" => @nested_router,
          "lib/test_web/live/things/thing_quick.ex" =>
            quick_source("TestWeb.ThingLive.Quick", "MyApp.Catalog.Thing"),
          "lib/test_web/live/widgets/widget_quick.ex" =>
            quick_source("TestWeb.WidgetLive.Quick", "AshQuick.Test.Gen.Widget")
        })

      assert_has_issue(igniter, &(&1 =~ "lib/test_web/live/widgets/widget_quick.ex"))
      assert_has_issue(igniter, &(&1 =~ "--file"))
    end

    test "takes an explicit file" do
      igniter =
        generate([
          "AshQuick.Test.Gen.Widget",
          "--file",
          "lib/test_web/live/stock/widget_quick.ex"
        ])

      assert_written(igniter, "lib/test_web/live/stock/widget_quick.ex")
      refute_written(igniter, @quick)
    end

    # Igniter keeps sources by their path relative to the project, so another
    # spelling of the same file would be moved back to the module's location.
    test "an explicit file is kept however it is spelled" do
      for file <- [
            "./lib/test_web/stock/widget_quick.ex",
            Path.expand("lib/test_web/stock/widget_quick.ex")
          ] do
        igniter = generate(["AshQuick.Test.Gen.Widget", "--file", file])

        assert_written(igniter, "lib/test_web/stock/widget_quick.ex")
      end
    end

    test "an explicit file wins over the QuickViews already routed" do
      igniter =
        generate(
          ["AshQuick.Test.Gen.Widget", "--file", "lib/test_web/stock/widget_quick.ex"],
          %{
            "lib/test_web/router.ex" => @nested_router,
            "lib/test_web/live/things/thing_quick.ex" =>
              quick_source("TestWeb.ThingLive.Quick", "MyApp.Catalog.Thing")
          }
        )

      assert_written(igniter, "lib/test_web/stock/widget_quick.ex")
    end

    test "says so when an explicit file shares a directory with another QuickView" do
      igniter =
        generate(
          ["AshQuick.Test.Gen.Widget", "--file", "lib/test_web/live/things/widget_quick.ex"],
          %{
            "lib/test_web/live/things/thing_quick.ex" =>
              quick_source("TestWeb.ThingLive.Quick", "MyApp.Catalog.Thing")
          }
        )

      assert_written(igniter, "lib/test_web/live/things/widget_quick.ex")
      assert_has_warning(igniter, &(&1 =~ "TestWeb.ThingLive.Quick"))
      assert_has_warning(igniter, &(&1 =~ "action_<name>.html.heex"))
    end

    test "an explicit file has to be an Elixir source file" do
      igniter = generate(["AshQuick.Test.Gen.Widget", "--file", "lib/test_web/widget_quick"])

      assert_has_issue(igniter, &(&1 =~ "--file"))
    end
  end

  describe "the route" do
    test "is one line, at the resource's plural name, in the AshQuick live_session" do
      assert_has_patch(widget(), "lib/test_web/router.ex", """
      + |      quick_view "/widgets", WidgetLive.Quick
      """)
    end

    test "takes an explicit path" do
      igniter = generate(["AshQuick.Test.Gen.Widget", "--path", "/admin/widgets"])

      assert diff(igniter) =~ ~s|quick_view "/admin/widgets", WidgetLive.Quick|
    end

    # `:except` names a route shape rather than a resource action, and this is
    # the shape worth deciding: the list page reads the routes back to decide
    # whether to offer a New button at all.
    test "omits /create for a resource nothing creates by hand" do
      igniter = generate(["AshQuick.Test.Gen.Ledger"])

      assert diff(igniter) =~
               ~s|quick_view "/ledger_entries", LedgerLive.Quick, except: [:create]|
    end

    test "goes next to the QuickViews already routed" do
      igniter =
        widget(%{
          "lib/test_web/router.ex" => """
          defmodule TestWeb.Router do
            use TestWeb, :router

            import AshQuick.LiveView.Router

            scope "/", TestWeb do
              quick_view "/things", TestWeb.ThingLive.Quick
            end
          end
          """
        })

      assert_has_patch(igniter, "lib/test_web/router.ex", """
        |    quick_view "/things", TestWeb.ThingLive.Quick
      + |    quick_view "/widgets", WidgetLive.Quick
      """)
    end

    test "is not written twice" do
      igniter =
        widget(%{
          "lib/test_web/router.ex" => """
          defmodule TestWeb.Router do
            use TestWeb, :router

            import AshQuick.LiveView.Router

            scope "/", TestWeb do
              quick_view "/widgets", TestWeb.WidgetLive.Quick
            end
          end
          """
        })

      assert_unchanged(igniter, "lib/test_web/router.ex")
    end

    # `scope "/", TestWeb` prefixes every module written inside it, so a route
    # declared there with the full name resolves to `TestWeb.TestWeb....` — a
    # module that does not exist. Phoenix has no escape from that, so a view
    # whose name cannot be written where the route would go is not written
    # there at all.
    test "refuses to place a route in a scope whose alias the view is not under" do
      igniter =
        widget(%{
          "lib/test_web/router.ex" => """
          defmodule TestWeb.Router do
            use TestWeb, :router

            import AshQuick.LiveView.Router

            scope "/", TestWeb do
              scope "/admin", Admin do
                quick_view "/things", ThingLive.Quick
              end
            end
          end
          """
        })

      assert_unchanged(igniter, "lib/test_web/router.ex")
      assert_has_warning(igniter, &(&1 =~ ~r|quick_view[ (]"/widgets", TestWeb.WidgetLive.Quick|))
    end

    test "and writes it under the alias when the view does sit there" do
      igniter =
        generate(["AshQuick.Test.Gen.Widget", "--module", "TestWeb.Admin.WidgetLive.Quick"], %{
          "lib/test_web/router.ex" => """
          defmodule TestWeb.Router do
            use TestWeb, :router

            import AshQuick.LiveView.Router

            scope "/", TestWeb do
              scope "/admin", Admin do
                quick_view "/things", ThingLive.Quick
              end
            end
          end
          """
        })

      assert diff(igniter) =~ ~s|quick_view "/widgets", WidgetLive.Quick|
    end

    test "keeps the full name in a scope that aliases nothing" do
      igniter =
        widget(%{
          "lib/test_web/router.ex" => """
          defmodule TestWeb.Router do
            use TestWeb, :router

            import AshQuick.LiveView.Router

            scope "/" do
              quick_view "/things", TestWeb.ThingLive.Quick
            end
          end
          """
        })

      assert diff(igniter) =~ ~s|quick_view "/widgets", TestWeb.WidgetLive.Quick|
    end

    test "says where to put it when there is nowhere obvious" do
      igniter =
        widget(%{
          "lib/test_web/router.ex" => """
          defmodule TestWeb.Router do
            use TestWeb, :router
          end
          """
        })

      assert_has_warning(igniter, &(&1 =~ "live_session"))
    end
  end

  # A route the router serves and the access control does not grant is a page
  # that 403s with nothing to say why, so both are written at once.
  describe "the grant" do
    test "adds the path to the access control" do
      assert_has_patch(widget(), "lib/test_web/access_control.ex", """
      - |  @routes []
      + |  @routes ["/widgets"]
      """)
    end

    test "does not grant it twice" do
      igniter =
        widget(%{
          "lib/test_web/access_control.ex" =>
            String.replace(@access_control, "@routes []", ~s|@routes ["/widgets"]|)
        })

      assert_unchanged(igniter, "lib/test_web/access_control.ex")
    end

    test "says what will catch it when there is no `@routes` list" do
      igniter =
        widget(%{"lib/test_web/access_control.ex" => @per_role_access_control})

      assert_unchanged(igniter, "lib/test_web/access_control.ex")
      assert_has_warning(igniter, &(&1 =~ "--grant-to"))
      assert_has_warning(igniter, &(&1 =~ "mix ash_quick.check --strict"))
    end

    test "grants it to the roles named, in their own clauses" do
      igniter =
        generate(
          ["AshQuick.Test.Gen.Widget", "--grant-to", "admin,member"],
          %{"lib/test_web/access_control.ex" => @per_role_access_control}
        )

      assert_has_patch(igniter, "lib/test_web/access_control.ex", """
      - |  def routes_for_role(:admin), do: ~w(/users)
      - |  def routes_for_role(:member), do: ["/products"]
      + |  def routes_for_role(:admin), do: ~w(/users /widgets)
      + |  def routes_for_role(:member), do: ["/products", "/widgets"]
      """)

      refute diff(igniter) =~ ~s|routes_for_role(_role), do: ["/widgets"]|
    end

    test "grants it in a multi-line word list on a line of its own" do
      igniter =
        generate(
          ["AshQuick.Test.Gen.Widget", "--grant-to", "admin"],
          %{
            "lib/test_web/access_control.ex" => """
            defmodule TestWeb.AccessControl do
              @behaviour AshQuick.AccessControl

              def routes_for_role(:admin) do
                ~w(
                  /users
                  /products
                )
              end

              def routes_for_role(_role), do: []

              @impl AshQuick.AccessControl
              def routes_for(scope), do: routes_for_role(scope.role)
            end
            """
          }
        )

      assert created(igniter, "lib/test_web/access_control.ex") =~
               "    ~w(\n      /users\n      /products\n      /widgets\n    )"
    end

    test "does not grant it twice to a role" do
      igniter =
        generate(
          ["AshQuick.Test.Gen.Widget", "--grant-to", "admin"],
          %{
            "lib/test_web/access_control.ex" =>
              String.replace(@per_role_access_control, "~w(/users)", "~w(/users /widgets)")
          }
        )

      assert_unchanged(igniter, "lib/test_web/access_control.ex")
    end

    test "says which roles it could not grant it to" do
      igniter =
        generate(
          ["AshQuick.Test.Gen.Widget", "--grant-to", "admin,owner,auditor"],
          %{"lib/test_web/access_control.ex" => @per_role_access_control}
        )

      assert diff(igniter) =~ "~w(/users /widgets)"
      assert_has_warning(igniter, &(&1 =~ ":owner" and &1 =~ ":auditor"))
      refute_warning(igniter, ":admin")
    end

    # Only the function `routes_for/1` hands the role to holds the roles'
    # routes: another clause on the same atom is about something else.
    test "reads only the clauses of the function routes_for/1 calls" do
      igniter =
        generate(
          ["AshQuick.Test.Gen.Widget", "--grant-to", "admin"],
          %{
            "lib/test_web/access_control.ex" => """
            defmodule TestWeb.AccessControl do
              @behaviour AshQuick.AccessControl

              def label(:admin), do: "Administrator"
              def landing_for_role(:admin), do: ["/dashboard"]
              def allowed(:admin), do: ~w(/users)
              def allowed(_role), do: []

              @impl AshQuick.AccessControl
              def routes_for(scope), do: Enum.uniq(allowed(scope.role))
            end
            """
          }
        )

      source = created(igniter, "lib/test_web/access_control.ex")
      assert source =~ "def allowed(:admin), do: ~w(/users /widgets)"
      assert source =~ ~s|def landing_for_role(:admin), do: ["/dashboard"]|
      assert source =~ ~s|def label(:admin), do: "Administrator"|
      assert igniter.warnings == []
    end

    test "follows the function routes_for/1 pipes the role into" do
      igniter =
        generate(
          ["AshQuick.Test.Gen.Widget", "--grant-to", "admin"],
          %{
            "lib/test_web/access_control.ex" => """
            defmodule TestWeb.AccessControl do
              @behaviour AshQuick.AccessControl

              def allowed(:admin), do: ~w(/users)

              @impl AshQuick.AccessControl
              def routes_for(scope), do: scope.role |> allowed()
            end
            """
          }
        )

      assert diff(igniter) =~ "def allowed(:admin), do: ~w(/users /widgets)"
      assert igniter.warnings == []
    end

    test "falls back to routes_for_role/1, past other clauses on the role" do
      igniter =
        generate(
          ["AshQuick.Test.Gen.Widget", "--grant-to", "admin"],
          %{
            "lib/test_web/access_control.ex" => """
            defmodule TestWeb.AccessControl do
              @behaviour AshQuick.AccessControl

              @routes_by_role %{}

              def landing_for_role(:admin), do: ["/dashboard"]
              def routes_for_role(:admin), do: ~w(/users)

              @impl AshQuick.AccessControl
              def routes_for(scope), do: Map.get(@routes_by_role, scope.role, [])
            end
            """
          }
        )

      source = created(igniter, "lib/test_web/access_control.ex")
      assert source =~ "def routes_for_role(:admin), do: ~w(/users /widgets)"
      assert source =~ ~s|def landing_for_role(:admin), do: ["/dashboard"]|
    end

    test "takes a role written as an atom" do
      igniter =
        generate(
          ["AshQuick.Test.Gen.Widget", "--grant-to", ":admin,:auditor"],
          %{"lib/test_web/access_control.ex" => @per_role_access_control}
        )

      assert diff(igniter) =~ "~w(/users /widgets)"
      assert_has_warning(igniter, &(&1 =~ "routes_for_role/1" and &1 =~ " :auditor"))
      refute_warning(igniter, "::")
    end

    test "names the roles rather than granting a `@routes` list everyone holds" do
      igniter = generate(["AshQuick.Test.Gen.Widget", "--grant-to", "admin"])

      assert_unchanged(igniter, "lib/test_web/access_control.ex")
      assert_has_warning(igniter, &(&1 =~ ":admin"))
    end

    test "says so when there is no access control to grant it in" do
      igniter =
        test_project(
          files: %{
            ".formatter.exs" => @formatter,
            "lib/test_web.ex" => @web_module,
            "lib/test_web/router.ex" => @router
          }
        )
        |> Igniter.compose_task("ash_quick.gen.quick_view", ["AshQuick.Test.Gen.Widget"])

      assert_has_notice(igniter, &(&1 =~ "not granted to anyone"))
    end
  end

  describe "what it refuses" do
    test "a name that resolves to nothing" do
      assert_has_issue(generate(["Nope.NotHere"]), &(&1 =~ "does not exist"))
    end

    test "a module that is not a resource" do
      assert_has_issue(generate(["AshQuick.Config"]), &(&1 =~ "not an Ash resource"))
    end

    # A QuickView over a resource without the extension has no display label, no
    # publications and no audit trail: the page looks healthy and is not.
    test "a resource that never took the extension on" do
      igniter = generate(["AshQuick.Test.Gen.Unadopted"])

      assert_has_issue(igniter, &(&1 =~ "does not carry the AshQuick extension"))
      assert_has_issue(igniter, &(&1 =~ "mix ash_quick.gen.resource"))
    end
  end

  # Where the file is once Igniter has written it, which is after it moves
  # every file it created to the place the module's name maps to.
  defp assert_written(igniter, path) do
    written = Igniter.Test.apply_igniter!(igniter)

    assert Map.has_key?(written.assigns.test_files, path),
           inspect(Map.keys(written.assigns.test_files))
  end

  defp refute_written(igniter, path) do
    written = Igniter.Test.apply_igniter!(igniter)
    refute Map.has_key?(written.assigns.test_files, path)
  end

  defp refute_warning(igniter, text) do
    refute Enum.any?(igniter.warnings, &(&1 =~ text)), inspect(igniter.warnings)
  end

  defp created(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end
end
