defmodule Mix.Tasks.AshQuick.InstallTest do
  @moduledoc """
  The installer, against a project shaped like the one it is meant for.

  Each assertion here is one of the steps the README asks an adopter to take by
  hand, and the two that matter most are the ones that fail silently when they
  are skipped: configuration landing in `config.exs` rather than `runtime.exs`,
  and an audit store existing at all.

  The generated resources are asserted as source rather than compiled, so the
  DSL calls are matched with their parentheses optional: the harness cannot
  resolve the package's own `.formatter.exs` through a project that only exists
  in memory, and a real host formats them away.
  """
  use ExUnit.Case, async: true

  import Igniter.Test

  @store "lib/test/audit_logs/audit_log.ex"

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

    scope "/", TestWeb do
      live_session :authenticated, on_mount: [AshQuick.LiveView.Mount] do
        live "/", HomeLive, :index
      end
    end
  end
  """

  @endpoint """
  defmodule TestWeb.Endpoint do
    use Phoenix.Endpoint, otp_app: :test

    plug TestWeb.Router
  end
  """

  @application """
  defmodule Test.Application do
    use Application

    @impl true
    def start(_type, _args) do
      children = [
        {Phoenix.PubSub, name: Test.PubSub},
        TestWeb.Endpoint
      ]

      Supervisor.start_link(children, strategy: :one_for_one, name: Test.Supervisor)
    end
  end
  """

  @core_components """
  defmodule TestWeb.CoreComponents do
    def translate_error({msg, _opts}), do: msg
  end
  """

  @user """
  defmodule Test.Accounts.User do
    use Ash.Resource, domain: Test.Accounts

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end
  end
  """

  @repo """
  defmodule Test.Repo do
    use AshPostgres.Repo, otp_app: :test
  end
  """

  @mix_exs """
  defmodule Test.MixProject do
    use Mix.Project

    def project do
      [app: :test, version: "0.1.0", elixir: "~> 1.19", deps: deps()]
    end

    def application do
      [extra_applications: [:logger]]
    end

    defp deps do
      [{:ash_postgres, "~> 2.0"}]
    end
  end
  """

  @css """
  @import "tailwindcss";

  @source "../js";
  """

  defp project(extra) do
    test_project(
      files:
        Map.merge(
          %{
            "lib/test_web.ex" => @web_module,
            "lib/test_web/router.ex" => @router,
            "lib/test_web/endpoint.ex" => @endpoint,
            "lib/test_web/components/core_components.ex" => @core_components,
            "lib/test/application.ex" => @application,
            "lib/test/accounts/user.ex" => @user,
            "assets/css/app.css" => @css
          },
          extra
        )
    )
  end

  defp install(extra \\ %{}, argv \\ []) do
    extra |> project() |> Igniter.compose_task("ash_quick.install", argv)
  end

  # The audit store is a Postgres table, and its indexes and its refusal to let
  # an actor be deleted are both data-layer declarations — so the branch that
  # writes them needs a project with a repo to write them against.
  defp install_with_repo(extra \\ %{}) do
    extra
    |> Map.merge(%{"mix.exs" => @mix_exs, "lib/test/repo.ex" => @repo})
    |> install()
  end

  describe "configuration" do
    test "writes the block into config.exs, where the compile_env reads can see it" do
      config = created(install(), "config/config.exs")

      assert config =~ """
             config :ash_quick,
               endpoint: TestWeb.Endpoint,
               actor_resource: Test.Accounts.User,
               audit_resource: Test.AuditLogs.AuditLog,
               nav: TestWeb.Nav,
               error_translator: {TestWeb.CoreComponents, :translate_error},
               timezone: "Etc/UTC"
             """
    end

    test "says why it is not in runtime.exs" do
      assert diff(install()) =~ "not in `runtime.exs`"
    end

    test "leaves the error translator out when the application has no CoreComponents" do
      igniter =
        install(%{
          "lib/test_web/components/core_components.ex" => "defmodule Unrelated do\nend\n"
        })

      refute diff(igniter) =~ "error_translator"
    end

    test "takes an actor resource and a timezone from the command line" do
      igniter =
        install(%{}, ["--actor-resource", "Test.People.Person", "--timezone", "Africa/Cairo"])

      diff = diff(igniter)

      assert diff =~ "actor_resource: Test.People.Person"
      assert diff =~ ~s|timezone: "Africa/Cairo"|
    end

    test "writes a section order with :ash_quick ahead of :pub_sub" do
      config = created(install(), "config/config.exs")

      assert config =~ ":ash_quick"

      {ash_quick, _} = :binary.match(config, ":ash_quick,")
      {pub_sub, _} = :binary.match(config, ":pub_sub,")

      assert ash_quick < pub_sub
    end

    # The order a project already had is kept, and only `:ash_quick` inserted —
    # in the one position that matters.
    test "inserts into a section order the project already declares" do
      igniter =
        install(%{
          "config/config.exs" => """
          import Config

          config :spark,
            formatter: [
              "Ash.Resource": [section_order: [:actions, :policies, :pub_sub, :attributes]]
            ]
          """
        })

      assert_has_patch(igniter, "config/config.exs", """
      - |    "Ash.Resource": [section_order: [:actions, :policies, :pub_sub, :attributes]]
      + |    "Ash.Resource": [section_order: [:actions, :policies, :ash_quick, :pub_sub, :attributes]]
      """)
    end
  end

  describe "the audit store" do
    test "generates the store, its domain, and the migration for both" do
      igniter = install()

      assert_creates(igniter, @store)
      assert_creates(igniter, "lib/test/audit_logs.ex")
      assert_has_task(igniter, "ash.codegen", ["install_ash_quick"])
    end

    # Every field is filled on every entry and written through the store's
    # `:create`, so one the store cannot take refuses the whole batch — from
    # inside the transaction of the write it was describing.
    test "the store takes every field an audit row carries" do
      source = created(install(), @store)

      for field <- AshQuick.Audit.Row.fields() do
        assert source =~ carrier(field), "the generated store cannot take #{field}"
      end
    end

    defp carrier(:actor_id), do: "belongs_to :actor, Test.Accounts.User"
    defp carrier(:real_actor_id), do: "belongs_to :real_actor, Test.Accounts.User"
    defp carrier(field), do: ~r/attribute[ (]:#{field},/

    test "the store is append-only, unpublished, and stamps no actor of its own" do
      source = created(install(), @store)

      assert source =~ ~r/defaults[ (]\[:create, :read\]/
      refute source =~ ":update"
      refute source =~ ":destroy"

      # Its own writes are the entries; recording them would recurse.
      assert source =~ ~r/liveness do\n.*\n.*\n\s*enabled\?[ (]false/
      assert source =~ ~r/created_by[ (]false/
      assert source =~ ~r/updated_by[ (]false/
    end

    # An entry that has forgotten who wrote it is not a record, so the actor it
    # names must not be deletable out from under it.
    test "the actor reference refuses a delete, and both reads are indexed" do
      source = created(install_with_repo(), @store)

      assert source =~ "data_layer: AshPostgres.DataLayer"
      assert source =~ ~r/repo[ (]Test\.Repo/
      assert source =~ ~r/reference[ (]:actor, on_delete: :restrict, on_update: :restrict/
      assert source =~ ~r/reference[ (]:real_actor, on_delete: :restrict, on_update: :restrict/

      assert source =~ ~r/index[ (]\[:resource_id, :resource_name\]/
      assert source =~ ~r/index[ (]\[:actor_id, :tenant\]/
    end

    test "falls back to plain columns when the application names no actor resource" do
      source =
        %{"lib/test/accounts/user.ex" => "defmodule Test.Unrelated do\nend\n"}
        |> install()
        |> created(@store)

      refute source =~ "relationships do"
      assert source =~ ~r/attribute[ (]:actor_id, :uuid/
      assert source =~ ~r/attribute[ (]:real_actor_id, :uuid/
    end

    test "leaves a store that is already there alone" do
      igniter =
        install(%{
          @store => """
          defmodule Test.AuditLogs.AuditLog do
            @moduledoc "Ours, with columns of our own."
          end
          """
        })

      assert_unchanged(igniter, @store)
    end

    # Generated without a data layer, the trail is not persisted anywhere — a
    # silence worth one line of noise.
    test "says so when there is no data layer to persist the trail in" do
      assert_has_warning(install(), &(&1 =~ "no Ecto repo"))
    end

    test "and says nothing when there is one" do
      refute Enum.any?(install_with_repo().warnings, &(&1 =~ "no Ecto repo"))
    end
  end

  describe "the nav and the access control" do
    test "generates both, with the nav naming the router and the access control" do
      igniter = install()

      assert_creates(igniter, "lib/test_web/access_control.ex")

      source = created(igniter, "lib/test_web/nav.ex")

      assert source =~
               "use AshQuick.Nav, router: TestWeb.Router, access_control: TestWeb.AccessControl"
    end

    test "the access control is the shape mix ash_quick.gen.quick_view appends to" do
      source = created(install(), "lib/test_web/access_control.ex")

      assert source =~ "@behaviour AshQuick.AccessControl"
      assert source =~ "@routes []"
      assert source =~ "def all_routes"
    end
  end

  describe "the router, the formatter and the client" do
    test "imports the macro every QuickView route goes through" do
      assert_has_patch(install(), "lib/test_web/router.ex", """
      + |  import AshQuick.LiveView.Router
      """)
    end

    test "does not import it twice" do
      igniter =
        install(%{
          "lib/test_web/router.ex" => """
          defmodule TestWeb.Router do
            use TestWeb, :router
            import AshQuick.LiveView.Router
          end
          """
        })

      assert_unchanged(igniter, "lib/test_web/router.ex")
    end

    test "says where to put the macro when there is no router" do
      igniter =
        test_project(files: %{"lib/test_web.ex" => @web_module})
        |> Igniter.compose_task("ash_quick.install", [])

      assert_has_warning(igniter, &(&1 =~ "import AshQuick.LiveView.Router"))
    end

    test "imports the DSL into the formatter" do
      assert_has_patch(install(), ".formatter.exs", """
      + |  import_deps: [:ash_quick]
      """)
    end

    test "supervises the register of signed-in tabs" do
      assert_has_patch(install(), "lib/test/application.ex", """
      + |      AshQuick.BrowserSessionPresence
      """)
    end

    # Without this every QuickView renders unstyled: the library's classes live
    # in its own lib/, which the host's Tailwind build does not scan.
    test "points the Tailwind build at the library's classes" do
      assert_has_patch(install(), "assets/css/app.css", """
      + |@source "../../deps/ash_quick/lib/**/*.*ex";
      """)
    end

    test "leaves the stylesheet alone on a second run" do
      igniter =
        install(%{
          "assets/css/app.css" => """
          @import "tailwindcss";
          @source "../../deps/ash_quick/lib/**/*.*ex";
          """
        })

      assert_unchanged(igniter, "assets/css/app.css")
    end

    test "warns rather than half-patches when there is no stylesheet" do
      igniter =
        test_project(files: %{"lib/test_web.ex" => @web_module})
        |> Igniter.compose_task("ash_quick.install", [])

      assert_has_warning(igniter, &(&1 =~ "assets/css/app.css"))
    end

    # The params have to become a function, so every reconnect re-reads the
    # tab's identity. That is a rewrite rather than a line to append, so it is
    # stated rather than guessed at.
    test "states the client half instead of patching it" do
      assert_has_notice(install(), &(&1 =~ "initBrowserSession"))
    end
  end

  defp created(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end
end
