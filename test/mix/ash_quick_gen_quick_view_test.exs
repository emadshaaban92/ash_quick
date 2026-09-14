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
      assert source =~ "fields: [:sku, :name, :created_at, :updated_at]"

      refute source =~ ":version"
      refute source =~ ":created_by_id"
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

  defp created(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end
end
