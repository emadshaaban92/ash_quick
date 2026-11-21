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
  in memory, and a real host formats them away. The audit store is the one
  exception: whether it takes a nil actor is a question about the compiled
  resource, so it is compiled too.
  """
  # Not async: while it runs a task, Igniter evaluates the project's generated
  # `config.exs` into the live application env (`Application.put_all_env`,
  # restored afterwards). Here that config sets `:ash_quick, :audit_resource`
  # to the generated `Test.AuditLogs.AuditLog`, so an async test auditing a
  # write in that window reads a module that does not exist.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
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
        quick_view "/things", ThingLive.Quick
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

  @app_js """
  import "phoenix_html"
  import {Socket} from "phoenix"
  import {LiveSocket} from "phoenix_live_view"
  import {hooks as colocatedHooks} from "phoenix-colocated/test"
  import topbar from "../vendor/topbar"

  const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
  const liveSocket = new LiveSocket("/live", Socket, {
    longPollFallbackMs: 2500,
    params: {_csrf_token: csrfToken},
    hooks: {...colocatedHooks},
  })
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
      refute_notice(igniter, "ash.gen.gettext")
    end

    # Stated, not run: it writes into the host's `priv/gettext`.
    test "says how to put Ash's messages in the catalogue the translator reads" do
      igniter = install()

      assert_has_notice(igniter, &(&1 =~ "mix ash.gen.gettext --domain errors"))
      refute diff(igniter) =~ "priv/gettext"
    end

    test "points AshQuick at the application's Gettext backend, and says how to fill it" do
      igniter =
        install(%{
          "lib/test_web/gettext.ex" =>
            "defmodule TestWeb.Gettext do\n  use Gettext.Backend, otp_app: :test\nend\n"
        })

      assert diff(igniter) =~ "gettext: TestWeb.Gettext"
      assert_has_notice(igniter, &(&1 =~ "mix ash_quick.gen.gettext"))
    end

    # Localize ships English data alone, so dates and money read in English in
    # any other locale until the host downloads it.
    test "says how to have dates and money read in the backend's locales" do
      igniter =
        install(%{
          "lib/test_web/gettext.ex" =>
            "defmodule TestWeb.Gettext do\n  use Gettext.Backend, otp_app: :test\nend\n"
        })

      assert_has_notice(
        igniter,
        &(&1 =~ "config/config.exs" and &1 =~ "otp_app: :test" and
            &1 =~ "mix localize.download_locales")
      )
    end

    # A catalogue is not Elixir, so the installer reads the host's disk for it.
    @tag :tmp_dir
    test "lists the locales the backend has a catalogue for", %{tmp_dir: tmp_dir} do
      for locale <- ~w(fr ar),
          do: File.mkdir_p!(Path.join(tmp_dir, "priv/gettext/#{locale}/LC_MESSAGES"))

      igniter =
        File.cd!(tmp_dir, fn ->
          install(%{
            "lib/test_web/gettext.ex" =>
              "defmodule TestWeb.Gettext do\n  use Gettext.Backend, otp_app: :test\nend\n"
          })
        end)

      assert_has_notice(igniter, &(&1 =~ ~s(supported_locales: ["ar", "fr"])))
    end

    test "marks the locales as an example when the backend has no catalogue yet" do
      igniter =
        install(%{
          "lib/test_web/gettext.ex" =>
            "defmodule TestWeb.Gettext do\n  use Gettext.Backend, otp_app: :test\nend\n"
        })

      assert_has_notice(
        igniter,
        &(&1 =~ "supported_locales: [:en, :ar]  # for example: the locales TestWeb.Gettext has")
      )
    end

    test "leaves the backend out when the application has none" do
      igniter = install()

      refute diff(igniter) =~ "gettext: "
      refute_notice(igniter, "ash_quick.gen.gettext")
      refute_notice(igniter, "localize.download_locales")
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

  describe "the error reporter" do
    test "writes Tower's default as a placeholder, and says it is one" do
      igniter = install()
      config = created(igniter, "config/config.exs")

      # Each comment directly above the block it explains.
      assert config =~
               ~r/delivers them\. \S+#module-reporters\nconfig :tower, reporters: \[Tower\.EphemeralReporter\]\n/

      assert config =~ ~r/not in `runtime\.exs`\.\nconfig :ash_quick,\n/
      assert config =~ "# AshQuick reports every error a page could not explain through Tower."

      assert_has_notice(igniter, &(&1 =~ "config :tower, reporters: [TowerSentry]"))
      assert_has_notice(igniter, &(&1 =~ "unconfigured_error_reporter"))
    end

    # The project's choice, in either spelling of `config`: neither a second
    # value written over it nor a notice asking for what is already there.
    test "leaves a :reporters the project already sets alone" do
      for existing <- [
            "config :tower, reporters: [TowerSentry]",
            "config :tower, :reporters, [TowerSentry]",
            "config :tower, log_level: :error, reporters: []"
          ] do
        igniter = install(%{"config/config.exs" => "import Config\n\n#{existing}\n"})
        config = created(igniter, "config/config.exs")

        assert config =~ existing
        refute config =~ "Tower.EphemeralReporter", existing
        refute_notice(igniter, "unconfigured_error_reporter")
      end
    end

    # Either file is read after `config.exs`, so a placeholder written there
    # would change nothing — and the notice would ask for what is done.
    test "leaves config.exs alone when prod.exs or runtime.exs sets the reporters" do
      for file <- ~w(config/prod.exs config/runtime.exs) do
        igniter =
          install(%{file => "import Config\n\nconfig :tower, reporters: [TowerSentry]\n"})

        refute created(igniter, "config/config.exs") =~ "Tower.EphemeralReporter", file
        refute_notice(igniter, "unconfigured_error_reporter")
      end
    end

    # Above the env import, as everything else in a Phoenix config.exs is, so
    # a dev.exs or prod.exs setting still wins over it.
    test "lands above the import of the environment's config" do
      igniter =
        install(%{
          "config/config.exs" => """
          import Config

          config :test, ecto_repos: [Test.Repo]

          import_config "\#{config_env()}.exs"
          """
        })

      config = created(igniter, "config/config.exs")
      {tower, _} = :binary.match(config, "config :tower, reporters: [Tower.EphemeralReporter]")
      {import, _} = :binary.match(config, "import_config")

      assert tower < import
      assert config =~ ~r/#module-reporters\nconfig :tower,/
    end

    test "adds the reporters beside other :tower settings, and keeps those" do
      igniter =
        install(%{"config/config.exs" => "import Config\n\nconfig :tower, log_level: :error\n"})

      config = created(igniter, "config/config.exs")

      assert config =~ "log_level: :error"
      assert config =~ "reporters: [Tower.EphemeralReporter]"
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

    test "the store's policies refuse every create and read" do
      source = created(install(), @store)

      assert source =~ "authorizers: [Ash.Policy.Authorizer]"
      assert source =~ ~r/policy[ (]action_type\(:create\)/
      assert source =~ ~r/policy[ (]action_type\(:read\)/
      refute source =~ ~r/^\s*authorize_if/m
    end

    test "the store is append-only, unpublished, and stamps no actor of its own" do
      source = created(install(), @store)

      assert source =~ ~r/defaults[ (]\[:create, :read\]/
      refute source =~ ":update"
      refute source =~ ":destroy"

      # Its own writes are the entries; recording them would recurse.
      assert source =~ ~r/liveness do\n.*\n.*\n\s*enabled\?[ (]false/
      assert source =~ ~r/inserted_by[ (]false/
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

      # Text, so a host keyed by integers can audit into it too.
      assert source =~ ~r/attribute[ (]:resource_id, :string/
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

    # A write with no actor is recorded with `actor_id: nil`, so a store that
    # refuses it would fail every background job's write. Compiled rather than
    # matched, in both branches: `allow_nil?` on a `belongs_to` is read off its
    # source attribute, which only the compiled resource has.
    test "the store compiles and takes a nil actor, related or not" do
      for {label, igniter} <- [
            related: install(),
            plain: install(%{"lib/test/accounts/user.ex" => "defmodule Test.Unrelated do\nend\n"})
          ] do
        store = compile_store(igniter, label == :related)

        assert Ash.Resource.Info.attribute(store, :actor_id).allow_nil?, "#{label}"
        assert Ash.Resource.Info.attribute(store, :real_actor_id).allow_nil?, "#{label}"

        # The verifier a host's resources run against this store, which is what
        # refuses to compile one that cannot take a nil actor.
        with_audit_resource(store, fn ->
          assert AshQuick.Audit.Verifier.verify(AshQuick.Test.Credential.spark_dsl_config()) ==
                   :ok
        end)

        assert {:ok, row} =
                 store
                 |> Ash.Changeset.for_create(:create, %{
                   resource_name: :credential,
                   resource_id: Ash.UUID.generate(),
                   action_type: :update,
                   action_name: :update,
                   attributes: %{},
                   arguments: %{},
                   context: %{action_source: "nightly_sync"},
                   actor_id: nil,
                   real_actor_id: nil
                 })
                 |> Ash.create(authorize?: false)

        assert row.actor_id == nil

        refused_by_default(store)
        audited_writes_land(store)
      end
    end

    # The write AshQuick actually makes: `Audit.Store.write/2`'s bulk insert,
    # from a create and an update, with an actor and under `authorize?: true`.
    # A refused batch would raise `AshQuick.Audit.WriteError` here.
    defp audited_writes_land(store) do
      with_audit_resource(store, fn ->
        assert AshQuick.Audit.Declaration.store(AshQuick.Test.Credential) == store
        actor = %{id: Ash.UUID.generate()}

        assert {:ok, credential} =
                 AshQuick.Test.Credential
                 |> Ash.Changeset.for_create(:create, %{name: "a"}, actor: actor)
                 |> Ash.create(authorize?: true)

        assert {:ok, _credential} =
                 credential
                 |> Ash.Changeset.for_update(:update, %{name: "b"}, actor: actor)
                 |> Ash.update(authorize?: true)
      end)
    end

    # AshQuick writes the trail with `authorize?: false`; everything else that
    # reaches the store, with or without an actor, is refused until the host's
    # policies say otherwise.
    defp refused_by_default(store) do
      for actor <- [nil, %{id: Ash.UUID.generate(), role: :admin}] do
        refute Ash.can?({store, :read}, actor), inspect(actor)
        refute Ash.can?({store, :create}, actor), inspect(actor)

        assert {:error, %Ash.Error.Forbidden{}} =
                 store
                 |> Ash.Changeset.for_create(:create, %{
                   resource_name: :credential,
                   resource_id: Ash.UUID.generate(),
                   action_type: :update,
                   action_name: :update,
                   attributes: %{},
                   arguments: %{},
                   context: %{}
                 })
                 |> Ash.create(actor: actor)

        assert {:error, %Ash.Error.Forbidden{}} = Ash.read(store, actor: actor)
      end
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
      assert source =~ "def routes_for_role(:admin), do: []"
      assert source =~ "def all_routes"
    end

    # Fail-closed as written: no scope, whatever it holds, reaches a route until
    # the host reads a role off it and grants that role the route.
    test "the access control grants no route to any scope" do
      source = created(install(), "lib/test_web/access_control.ex")
      namespace = "InstallProbe#{:erlang.unique_integer([:positive])}"

      output =
        capture_io(:stderr, fn ->
          source |> String.replace("TestWeb.", namespace <> ".") |> Code.compile_string()
        end)

      assert output == "", output

      access_control = Module.concat(namespace, AccessControl)

      for scope <- [nil, %{}, %{current_user: %{role: :admin}}, %{role: :admin}] do
        assert access_control.routes_for(scope) == [], inspect(scope)
        refute AshQuick.LiveView.RouteGate.allowed?(access_control, scope, "/"), inspect(scope)
      end

      assert access_control.routes_for_role(:admin) == []
      assert access_control.all_routes() == []
    end

    test "says the generated defaults refuse until granted" do
      assert_has_notice(install(), &(&1 =~ "grants no route" and &1 =~ ":read` policy"))
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

      refute diff(igniter, only: "lib/test_web/router.ex") =~ ~r/\+ \|\s+import AshQuick/
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

    test "supervises AshQuick after the PubSub server" do
      assert_has_patch(install(), "lib/test/application.ex", """
      + |      AshQuick
      """)
    end

    # Without this every QuickView renders unstyled: the library's classes live
    # in its own lib/, which the host's Tailwind build does not scan.
    test "points the Tailwind build at the library's classes" do
      assert_has_patch(install(), "assets/css/app.css", """
      + |@source "../../deps/ash_quick/lib/**/*.*ex";
      """)
    end

    # The action modal's spinner, and its controls going still while the action
    # runs, hang on it. A new Phoenix app has it; an older one may not.
    test "defines the submit-loading variant when the stylesheet lacks it" do
      assert_has_patch(install(), "assets/css/app.css", """
      + |@custom-variant phx-submit-loading (.phx-submit-loading&, .phx-submit-loading &);
      """)
    end

    test "leaves the stylesheet alone on a second run" do
      igniter =
        install(%{
          "assets/css/app.css" => """
          @import "tailwindcss";
          @source "../../deps/ash_quick/lib/**/*.*ex";
          @custom-variant phx-submit-loading (.phx-submit-loading&, .phx-submit-loading &);
          """
        })

      assert_unchanged(igniter, "assets/css/app.css")
    end

    # Phoenix's own LiveSocket, its options wrapped and the socket attached:
    # the host's options stay as they are.
    test "wires AshQuick into the LiveSocket" do
      igniter = install(%{"assets/js/app.js" => @app_js})

      assert_content_equals(igniter, "assets/js/app.js", """
      import "phoenix_html"
      import {Socket} from "phoenix"
      import {LiveSocket} from "phoenix_live_view"
      import {withAshQuick, attachAshQuick} from "ash_quick"
      import {hooks as colocatedHooks} from "phoenix-colocated/test"
      import topbar from "../vendor/topbar"

      const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
      const liveSocket = new LiveSocket("/live", Socket, withAshQuick({
        longPollFallbackMs: 2500,
        params: {_csrf_token: csrfToken},
        hooks: {...colocatedHooks},
      }))
      attachAshQuick(liveSocket)
      """)
    end

    # Brackets and commas inside strings and comments are not the call's.
    test "wraps options named by a variable, past strings and comments" do
      app_js = """
      import {Socket} from "phoenix"
      import {LiveSocket, createHook} from "phoenix_live_view";

      let socket = new LiveSocket("/live(,)", Socket /* ) */, opts); // ok
      socket.connect();
      """

      igniter = install(%{"assets/js/app.js" => app_js})

      assert_content_equals(igniter, "assets/js/app.js", """
      import {Socket} from "phoenix"
      import {LiveSocket, createHook} from "phoenix_live_view";
      import {withAshQuick, attachAshQuick} from "ash_quick"

      let socket = new LiveSocket("/live(,)", Socket /* ) */, withAshQuick(opts)); // ok
      attachAshQuick(socket)
      socket.connect();
      """)
    end

    test "keeps the host's semicolons" do
      app_js = """
      import {LiveSocket} from "phoenix_live_view";
      const liveSocket = new LiveSocket("/live", Socket, {});
      """

      igniter = install(%{"assets/js/app.js" => app_js})

      assert_content_equals(igniter, "assets/js/app.js", """
      import {LiveSocket} from "phoenix_live_view";
      import {withAshQuick, attachAshQuick} from "ash_quick"
      const liveSocket = new LiveSocket("/live", Socket, withAshQuick({}));
      attachAshQuick(liveSocket);
      """)
    end

    test "leaves the script alone on a second run" do
      igniter = install(%{"assets/js/app.js" => @app_js})
      [source] = Enum.filter(Rewrite.sources(igniter.rewrite), &(&1.path == "assets/js/app.js"))
      installed = Rewrite.Source.get(source, :content)

      assert_unchanged(install(%{"assets/js/app.js" => installed}), "assets/js/app.js")
    end

    # Patching beside a setup written by hand would register every listener
    # twice, so it is left for the host to replace.
    test "says how to replace a setup written by hand" do
      app_js = """
      import {Socket} from "phoenix"
      import {LiveSocket} from "phoenix_live_view"
      import {initLocale} from "../../deps/ash_quick/assets/js/locale"
      import {hooks as ashQuickHooks} from "phoenix-colocated/ash_quick"
      """

      igniter = install(%{"assets/js/app.js" => app_js})

      assert_unchanged(igniter, "assets/js/app.js")
      assert_has_warning(igniter, &(&1 =~ "initLocale"))
    end

    test "says how to wire it in when it cannot find Phoenix's LiveSocket" do
      igniter = install(%{"assets/js/app.js" => ~s|import "phoenix_html"\n|})

      assert_unchanged(igniter, "assets/js/app.js")
      assert_has_warning(igniter, &(&1 =~ "attachAshQuick(liveSocket)"))
    end

    test "says how to wire it in when the socket is not built the usual way" do
      app_js = """
      import {LiveSocket} from "phoenix_live_view"
      window.liveSocket = new LiveSocket("/live", Socket, {})
      """

      igniter = install(%{"assets/js/app.js" => app_js})

      assert_unchanged(igniter, "assets/js/app.js")
      assert_has_warning(igniter, &(&1 =~ "withAshQuick({"))
    end

    test "warns rather than half-patches when there is no stylesheet" do
      igniter =
        test_project(files: %{"lib/test_web.ex" => @web_module})
        |> Igniter.compose_task("ash_quick.install", [])

      assert_has_warning(igniter, &(&1 =~ "assets/css/app.css"))
    end
  end

  # `mod:` named, so the tree is found where it is rather than created, and
  # the run can be written out.
  @mix_exs_with_mod """
  defmodule Test.MixProject do
    use Mix.Project

    def project, do: [app: :test, version: "0.1.0", elixir: "~> 1.19"]

    def application, do: [mod: {Test.Application, []}, extra_applications: [:logger]]
  end
  """

  describe "daisyUI" do
    # Every component is written in its classes, and a stylesheet without the
    # plugin draws them unstyled with no error anywhere.
    test "warns when the stylesheet loads no daisyUI plugin" do
      assert_has_warning(
        install(),
        &(&1 =~ "daisyUI" and &1 =~ ~s|@plugin "daisyui/packages/bundle/daisyui"|)
      )
    end

    test "says nothing when the stylesheet loads it the way Phoenix 1.8 does" do
      igniter =
        install(%{
          "assets/css/app.css" => """
          @import "tailwindcss";
          @plugin "../vendor/daisyui" {
            themes: false;
          }
          """
        })

      refute_warning(igniter, "daisyUI")
    end

    test "says nothing when a Tailwind 3 config requires it" do
      igniter =
        install(%{
          "assets/tailwind.config.js" => """
          module.exports = {plugins: [require("daisyui")]}
          """
        })

      refute_warning(igniter, "daisyUI")
    end

    test "says nothing when it is loaded from the dependency mix phx.new adds" do
      igniter =
        install(%{
          "assets/css/app.css" => """
          @import "tailwindcss";
          @plugin "daisyui/packages/bundle/daisyui" {
            themes: false;
          }
          """
        })

      refute_warning(igniter, "daisyUI")
    end

    test "the bundle's theme plugin alone is not the plugin" do
      igniter =
        install(%{
          "assets/css/app.css" => """
          @import "tailwindcss";
          @plugin "daisyui/packages/bundle/daisyui-theme" {
            name: "light";
          }
          """
        })

      assert_has_warning(igniter, &(&1 =~ "daisyUI"))
    end

    test "says nothing when it is loaded from a vendored daisyui.js" do
      igniter =
        install(%{
          "assets/css/app.css" => """
          @import "tailwindcss";
          @plugin "../vendor/daisyui.js";
          """
        })

      refute_warning(igniter, "daisyUI")
    end

    test "a plugin commented out is not loaded" do
      igniter =
        install(%{
          "assets/css/app.css" => """
          @import "tailwindcss";
          /* @plugin "../vendor/daisyui"; */
          """
        })

      assert_has_warning(igniter, &(&1 =~ "daisyUI"))
    end

    test "the theme plugin alone is not the plugin" do
      igniter =
        install(%{
          "assets/css/app.css" => """
          @import "tailwindcss";
          @plugin "../vendor/daisyui-theme" {
            name: "light";
          }
          """
        })

      assert_has_warning(igniter, &(&1 =~ "daisyUI"))
    end
  end

  describe "a live session that already runs the mount" do
    test "gets the route gate, last" do
      assert_has_patch(install(), "lib/test_web/router.ex", """
      + |    live_session :authenticated,
      + |      on_mount: [AshQuick.LiveView.Mount, AshQuick.LiveView.RouteGate] do
      """)
    end

    test "and nothing else: the project's own shell stays as it is" do
      igniter = install()

      refute_creates(igniter, "lib/test/scope.ex")
      refute_creates(igniter, "lib/test_web/quick_session.ex")
      refute_creates(igniter, "lib/test_web/quick_layouts.ex")
      refute diff(igniter) =~ "live_session :ash_quick"
    end

    test "is left alone when it has a gate already" do
      igniter =
        install(%{
          "lib/test_web/router.ex" => """
          defmodule TestWeb.Router do
            use TestWeb, :router
            import AshQuick.LiveView.Router

            scope "/", TestWeb do
              live_session :authenticated,
                on_mount: [AshQuick.LiveView.Mount, AshQuick.LiveView.RouteGate] do
                live "/", HomeLive, :index
                quick_view "/things", ThingLive.Quick
              end
            end
          end
          """
        })

      refute diff(igniter, only: "lib/test_web/router.ex") =~ "RouteGate,"
    end

    test "is found through an alias, and gated" do
      igniter =
        install(%{
          "lib/test_web/router.ex" => """
          defmodule TestWeb.Router do
            use TestWeb, :router
            import AshQuick.LiveView.Router
            alias AshQuick.LiveView.Mount

            scope "/", TestWeb do
              live_session :authenticated, on_mount: [Mount, {TestWeb.UserAuth, :assign_scope}] do
                live "/", HomeLive, :index
                quick_view "/things", ThingLive.Quick
              end
            end
          end
          """
        })

      assert diff(igniter, only: "lib/test_web/router.ex") =~
               ~r/\+ \|.*AshQuick\.LiveView\.RouteGate/

      refute_creates(igniter, "lib/test_web/quick_session.ex")
      refute_warning(igniter, "is already there")
    end

    test "is not gated twice when it names the gate through an alias" do
      igniter =
        install(%{
          "lib/test_web/router.ex" => """
          defmodule TestWeb.Router do
            use TestWeb, :router
            import AshQuick.LiveView.Router
            alias AshQuick.LiveView.RouteGate

            scope "/", TestWeb do
              live_session :authenticated, on_mount: [AshQuick.LiveView.Mount, RouteGate] do
                live "/", HomeLive, :index
                quick_view "/things", ThingLive.Quick
              end
            end
          end
          """
        })

      refute diff(igniter, only: "lib/test_web/router.ex") =~ "AshQuick.LiveView.RouteGate"
    end

    # A router `use`s its web module, which Igniter's own alias expansion stops
    # at; `Phoenix.Router` is a compiled module, as a real web module is.
    test "is found through an alias in a router that uses a compiled module" do
      igniter =
        install(%{
          "lib/test_web/router.ex" => """
          defmodule TestWeb.Router do
            use Phoenix.Router
            import AshQuick.LiveView.Router
            alias AshQuick.LiveView.{Mount, RouteGate}

            scope "/", TestWeb do
              live_session :authenticated, on_mount: [Mount] do
                live "/", HomeLive, :index
                quick_view "/things", ThingLive.Quick
              end

              live_session :gated, on_mount: [Mount, RouteGate] do
                live "/other", OtherLive, :index
              end
            end
          end
          """
        })

      router = diff(igniter, only: "lib/test_web/router.ex")

      assert router =~ ~r/\+ \|.*on_mount: \[Mount, AshQuick\.LiveView\.RouteGate\]/
      refute router =~ ~r/RouteGate, AshQuick\.LiveView\.RouteGate/
      refute_creates(igniter, "lib/test_web/quick_session.ex")
      refute_warning(igniter, "is already there")
    end

    test "is found through an alias with `as:`" do
      igniter =
        install(%{
          "lib/test_web/router.ex" => """
          defmodule TestWeb.Router do
            use Phoenix.Router
            import AshQuick.LiveView.Router
            alias AshQuick.LiveView.Mount, as: QuickMount

            scope "/", TestWeb do
              live_session :authenticated, on_mount: [{QuickMount, :default}] do
                live "/", HomeLive, :index
                quick_view "/things", ThingLive.Quick
              end
            end
          end
          """
        })

      assert diff(igniter, only: "lib/test_web/router.ex") =~
               ~r/\+ \|.*AshQuick\.LiveView\.RouteGate/

      refute_creates(igniter, "lib/test_web/quick_session.ex")
    end

    # Only a literal list can be appended to; anything else is named instead.
    test "is named in a warning when its stages are not a list" do
      igniter =
        install(%{
          "lib/test_web/router.ex" => """
          defmodule TestWeb.Router do
            use TestWeb, :router
            import AshQuick.LiveView.Router

            scope "/", TestWeb do
              live_session :single, on_mount: {AshQuick.LiveView.Mount, :default} do
                live "/", HomeLive, :index
                quick_view "/things", ThingLive.Quick
              end
            end
          end
          """
        })

      assert_has_warning(
        igniter,
        &(&1 =~ ":single" and &1 =~ "AshQuick.LiveView.RouteGate")
      )

      refute diff(igniter, only: "lib/test_web/router.ex") =~ "RouteGate"
      refute_creates(igniter, "lib/test_web/quick_session.ex")
    end

    # The mount belongs on a sign-in page too, and a gate there would answer
    # every signed-out visitor, whom no route is granted to, with a 403.
    test "leaves a session that routes no QuickView, such as the sign-in page's, ungated" do
      igniter =
        install(%{
          "lib/test_web/router.ex" => """
          defmodule TestWeb.Router do
            use Phoenix.Router
            import AshQuick.LiveView.Router

            scope "/", TestWeb do
              live_session :no_user,
                on_mount: [AshQuick.LiveView.Mount, {TestWeb.UserAuth, :live_no_user}] do
                live "/login", LoginLive, :index
              end

              live_session :authenticated, on_mount: [AshQuick.LiveView.Mount] do
                quick_view "/things", ThingLive.Quick
              end
            end
          end
          """
        })

      router = diff(igniter, only: "lib/test_web/router.ex")

      assert router =~ "on_mount: [AshQuick.LiveView.Mount, AshQuick.LiveView.RouteGate] do"
      refute router =~ "live_no_user}, AshQuick.LiveView.RouteGate"
    end

    test "is told apart from a sign-in session that is the only one running the mount" do
      igniter =
        install(%{
          "mix.exs" => @mix_exs_with_mod,
          "lib/test_web/router.ex" => """
          defmodule TestWeb.Router do
            use Phoenix.Router
            import AshQuick.LiveView.Router

            scope "/", TestWeb do
              live_session :no_user, on_mount: [AshQuick.LiveView.Mount] do
                live "/login", LoginLive, :index
              end
            end
          end
          """
        })

      diff = diff(igniter, only: "lib/test_web/router.ex")

      assert diff =~ "live_session :ash_quick"
      refute diff =~ ~r/no_user[^\n]*RouteGate/
    end

    # Igniter cannot see inside a module attribute, a variable or a call, so
    # such a session may be the QuickViews' own: neither gated nor doubled.
    test "is named in a warning, with no shell beside it, when its stages cannot be read" do
      igniter =
        install(%{
          "lib/test_web/router.ex" => """
          defmodule TestWeb.Router do
            use Phoenix.Router
            import AshQuick.LiveView.Router

            @stages [AshQuick.LiveView.Mount, {TestWeb.UserAuth, :assign_scope}]

            scope "/", TestWeb do
              live_session :authenticated, on_mount: @stages do
                live "/a", ALive, :index
              end
            end
          end
          """
        })

      assert_has_warning(
        igniter,
        &(&1 =~ ":authenticated" and &1 =~ "@stages" and &1 =~ "cannot read")
      )

      refute diff(igniter, only: "lib/test_web/router.ex") =~ "live_session :ash_quick"
      refute_creates(igniter, "lib/test_web/quick_session.ex")
    end

    # An alias in one scope says nothing about the name in another.
    test "reads an alias only where it is in scope" do
      igniter =
        install(%{
          "lib/test_web/router.ex" => """
          defmodule TestWeb.Router do
            use Phoenix.Router
            import AshQuick.LiveView.Router

            scope "/", TestWeb do
              alias AshQuick.LiveView.Mount

              live_session :authenticated, on_mount: [Mount] do
                quick_view "/things", ThingLive.Quick
              end
            end

            scope "/other", TestWeb do
              alias TestWeb.Mount

              live_session :other, on_mount: [Mount] do
                quick_view "/others", OtherLive.Quick
              end
            end
          end
          """
        })

      router = diff(igniter, only: "lib/test_web/router.ex")

      assert router =~
               ~r/live_session :authenticated,\s+on_mount: \[Mount, AshQuick\.LiveView\.RouteGate\]/

      refute router =~ ~r/live_session :other,\s+on_mount: \[Mount, AshQuick/
      refute router =~ "live_session :ash_quick"
    end

    test "is not thrown by an alias it cannot spell out" do
      igniter =
        install(%{
          "lib/test_web/router.ex" => """
          defmodule TestWeb.Router do
            use Phoenix.Router
            import AshQuick.LiveView.Router
            alias __MODULE__.Stages

            scope "/", TestWeb do
              live_session :authenticated, on_mount: [AshQuick.LiveView.Mount, Stages] do
                quick_view "/things", ThingLive.Quick
              end
            end
          end
          """
        })

      assert diff(igniter, only: "lib/test_web/router.ex") =~ "AshQuick.LiveView.RouteGate"
    end

    # A gate of the project's own, named to the check, is the gate: a second one
    # would answer with a 403 the scopes it lets through on purpose.
    test "is left alone when the project names a gate of its own" do
      igniter =
        install(%{
          "config/config.exs" => """
          import Config

          config :ash_quick, check: [gates: [{TestWeb.UserAuth, :require_user}]]
          """
        })

      refute diff(igniter, only: "lib/test_web/router.ex") =~ "RouteGate"
    end
  end

  describe "a router that runs the mount nowhere" do
    @plain_router """
    defmodule TestWeb.Router do
      use TestWeb, :router

      pipeline :browser do
        plug :accepts, ["html"]
      end

      scope "/", TestWeb do
        pipe_through :browser

        get "/", PageController, :home
      end
    end
    """

    @ash_authentication_router """
    defmodule TestWeb.Router do
      use TestWeb, :router
      use AshAuthentication.Phoenix.Router

      pipeline :browser do
        plug :accepts, ["html"]
      end

      scope "/", TestWeb do
        pipe_through :browser

        get "/", PageController, :home
      end
    end
    """

    @account """
    defmodule Test.Accounts.Account do
      use Ash.Resource, domain: Test.Accounts

      attributes do
        uuid_primary_key :id
      end
    end
    """

    defp install_account do
      %{
        "lib/test_web/router.ex" => @ash_authentication_router,
        "mix.exs" => @mix_exs_with_mod,
        "lib/test/accounts/account.ex" => @account
      }
      |> install(["--actor-resource", "Test.Accounts.Account"])
    end

    defp shell(router \\ @plain_router, extra \\ %{}) do
      extra
      |> Map.merge(%{"lib/test_web/router.ex" => router, "mix.exs" => @mix_exs_with_mod})
      |> install()
    end

    test "gets a live session with the mount first and the gate last" do
      assert_has_patch(shell(), "lib/test_web/router.ex", """
      + |    live_session :ash_quick,
      + |      layout: {TestWeb.QuickLayouts, :app},
      + |      on_mount: [
      + |        AshQuick.LiveView.Mount,
      + |        {TestWeb.QuickSession, :assign_scope},
      + |        {TestWeb.QuickSession, :require_user},
      + |        AshQuick.LiveView.RouteGate
      + |      ] do
      + |    end
      """)
    end

    test "in the scope its browser pipeline serves" do
      router = shell() |> Igniter.Test.apply_igniter!() |> source("lib/test_web/router.ex")

      assert router =~
               ~r/pipe_through\(?:browser\)?\s+get\(?"\/", PageController, :home\)?\s+live_session :ash_quick/
    end

    test "generates the scope, the session's stages and the layout" do
      igniter = shell()

      assert_creates(igniter, "lib/test/scope.ex")
      assert_creates(igniter, "lib/test_web/quick_session.ex")
      assert_creates(igniter, "lib/test_web/quick_layouts.ex")

      assert created(igniter, "lib/test/scope.ex") =~ "use AshQuick.Scope"
      assert created(igniter, "lib/test_web/quick_session.ex") =~ "Test.Scope.new("
      assert created(igniter, "lib/test_web/quick_layouts.ex") =~ "<.sidebar"
    end

    # Igniter moves a created file to its module's mapped path when it writes.
    test "where they stay once written" do
      files =
        shell()
        |> Igniter.Test.apply_igniter!()
        |> Map.fetch!(:assigns)
        |> Map.fetch!(:test_files)

      assert Map.has_key?(files, "lib/test/scope.ex")
      assert Map.has_key?(files, "lib/test_web/quick_session.ex")
      assert Map.has_key?(files, "lib/test_web/quick_layouts.ex")
    end

    test "the three compile" do
      igniter = shell()
      namespace = "ShellProbe#{:erlang.unique_integer([:positive])}"

      source =
        ["lib/test/scope.ex", "lib/test_web/quick_session.ex", "lib/test_web/quick_layouts.ex"]
        |> Enum.map_join("\n", &created(igniter, &1))
        |> String.replace(~r/\bTest(Web)?\./, "#{namespace}\\1.")

      output = capture_io(:stderr, fn -> Code.compile_string(source) end)

      refute output =~ "warning", output
      refute output =~ "error", output
    end

    test "says the signed-in user has to reach the socket ahead of the mount" do
      assert_has_notice(shell(), &(&1 =~ "@current_user" and &1 =~ "@sign_in_path"))
      assert created(shell(), "lib/test_web/quick_session.ex") =~ ~s|@sign_in_path "/sign-in"|
    end

    test "is AshAuthentication's live session when the router uses it" do
      igniter = shell(@ash_authentication_router)

      assert diff(igniter) =~ "ash_authentication_live_session :ash_quick,"
      assert created(igniter, "lib/test_web/quick_session.ex") =~ ~s|@sign_in_path "/sign-in"|
      refute_notice(igniter, "@sign_in_path")
    end

    # AshAuthentication assigns `current_<subject>`, the resource's short name.
    test "names the actor's assign when AshAuthentication's subject is not a user" do
      igniter = install_account()

      assert diff(igniter, only: "config/config.exs") =~ "actor_assign: :current_account"
    end

    test "writes the AshAuthentication session into the instructions it gives instead" do
      igniter =
        shell(@ash_authentication_router, %{
          "lib/test/scope.ex" => """
          defmodule Test.Scope do
            defstruct [:user]
          end
          """
        })

      assert_has_warning(igniter, &(&1 =~ "ash_authentication_live_session :ash_quick"))
    end

    test "uses no :browser pipeline the router does not have" do
      igniter =
        shell("""
        defmodule TestWeb.Router do
          use TestWeb, :router
        end
        """)

      refute diff(igniter) =~ "pipe_through"
      assert diff(igniter) =~ "live_session :ash_quick"
    end

    # The stages would have to call its own constructor, whose options only the
    # project knows.
    test "is told how to write the session when the project has a scope already" do
      igniter =
        shell(@plain_router, %{
          "lib/test/web_scope.ex" => """
          defmodule Test.WebScope do
            use AshQuick.Scope, actor: :user

            defstruct [:user]
          end
          """
        })

      assert_has_warning(
        igniter,
        &(&1 =~ "Test.WebScope" and &1 =~ "AshQuick.LiveView.RouteGate")
      )

      refute_creates(igniter, "lib/test_web/quick_session.ex")
      refute diff(igniter) =~ "live_session :ash_quick"
    end

    test "and when a module already has the scope's name" do
      igniter =
        shell(@plain_router, %{
          "lib/test/scope.ex" => """
          defmodule Test.Scope do
            defstruct [:user]
          end
          """
        })

      assert_has_warning(igniter, &(&1 =~ "Test.Scope"))
      refute diff(igniter) =~ "live_session :ash_quick"
    end

    test "changes nothing more on a second run" do
      installed = shell() |> Igniter.Test.apply_igniter!()
      router = source(installed, "lib/test_web/router.ex")

      again =
        router
        |> shell(%{
          "lib/test/scope.ex" => source(installed, "lib/test/scope.ex"),
          "lib/test_web/quick_session.ex" => source(installed, "lib/test_web/quick_session.ex"),
          "lib/test_web/quick_layouts.ex" => source(installed, "lib/test_web/quick_layouts.ex")
        })

      assert_unchanged(again, [
        "lib/test_web/router.ex",
        "lib/test/scope.ex",
        "lib/test_web/quick_session.ex",
        "lib/test_web/quick_layouts.ex"
      ])
    end
  end

  # The generated store and its domain — with the user resource and a domain
  # for it, when the store relates one — compiled under a namespace of their
  # own, so the two branches do not redefine each other. Compiled as the
  # configured store, as a host's is, so it is not audited into itself.
  defp compile_store(igniter, related?) do
    namespace = "InstallProbe#{:erlang.unique_integer([:positive])}"

    accounts =
      if related? do
        [
          """
          defmodule Test.Accounts do
            use Ash.Domain, validate_config_inclusion?: false

            resources do
              resource Test.Accounts.User
            end
          end
          """,
          @user
        ]
      else
        []
      end

    source =
      (accounts ++ [created(igniter, "lib/test/audit_logs.ex"), created(igniter, @store)])
      |> Enum.join("\n")
      |> String.replace(~r/\bTest\./, namespace <> ".")

    store = Module.concat([namespace, "AuditLogs", "AuditLog"])

    # A verifier reports on stderr rather than raising out of
    # `Code.compile_string/1`. The domain is not in this app's `ash_domains`,
    # which Ash warns about there too — that one is not the store's.
    output =
      with_audit_resource(store, fn ->
        capture_io(:stderr, fn -> Code.compile_string(source) end)
      end)

    refute output =~ "Error", output

    store
  end

  defp with_audit_resource(store, fun) do
    original = Application.get_env(:ash_quick, :audit_resource)
    Application.put_env(:ash_quick, :audit_resource, store)

    try do
      fun.()
    after
      Application.put_env(:ash_quick, :audit_resource, original)
    end
  end

  defp refute_notice(igniter, text) do
    refute Enum.any?(igniter.notices, &(&1 =~ text)), "unexpected notice containing #{text}"
  end

  defp refute_warning(igniter, text) do
    refute Enum.any?(igniter.warnings, &(&1 =~ text)), "unexpected warning containing #{text}"
  end

  defp source(igniter, path), do: Map.fetch!(igniter.assigns.test_files, path)

  defp created(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end
end
