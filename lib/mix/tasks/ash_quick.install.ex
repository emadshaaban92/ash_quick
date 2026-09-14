if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshQuick.Install do
    @example "mix igniter.install ash_quick"

    @shortdoc "Configures AshQuick and generates the audit store, the nav and the access control"

    @moduledoc """
    Wires AshQuick into a Phoenix application.

    ```bash
    #{@example}
    ```

    Everything here is what the README asks an adopter to do by hand, and it is
    a task rather than a checklist because two of the steps fail silently when
    they are skipped: configuration in `runtime.exs` leaves every page dead
    rather than erroring, and a resource with no audit store compiles clean and
    then refuses every write.

    What it does:

      * Writes `config :ash_quick` into `config/config.exs` — never
        `runtime.exs`, because `:endpoint` and `:actor_resource` are
        `Application.compile_env/2` reads.
      * Generates the audit store, its domain and its migration. Generated into
        the application rather than shipped as a library resource, because
        projects add columns to it.
      * Generates a starter `AccessControl` and a `Nav`, the two modules the
        sidebar and the apps grid are rendered from.
      * Imports `AshQuick.LiveView.Router` into the router, since a QuickView
        reached through a plain `live/3` has no base path and says so at request
        time.
      * Adds `:ash_quick` to `import_deps` and to Spark's `section_order`.
      * Supervises `AshQuick.BrowserSessionPresence`, and points the Tailwind
        build at the library's own classes.

    ## Options

      * `--actor-resource` - The resource a record's `created_by` / `updated_by`
        point at, and that an audit entry names. Detected when the application
        has exactly one `User`-shaped resource.
      * `--audit-resource` - Where to generate the audit store. Defaults to
        `MyApp.AuditLogs.AuditLog`; its domain is taken from the name.
      * `--timezone` - The timezone dates and timestamps are displayed in.
        Defaults to `Etc/UTC`.
    """

    use Igniter.Mix.Task

    # The order the library's own resources are formatted in. `:ash_quick`
    # sorts after `:policies` and before `:pub_sub`: the extension writes the
    # `pub_sub` section itself, and a section Spark does not name sorts last,
    # which would leave a hand-written `pub_sub` block above it.
    @section_order [
      :postgres,
      :resource,
      :code_interface,
      :actions,
      :policies,
      :ash_quick,
      :pub_sub,
      :preparations,
      :changes,
      :validations,
      :multitenancy,
      :attributes,
      :relationships,
      :calculations,
      :aggregates,
      :identities
    ]

    @config_comment """
    Everything AshQuick needs from the application around it. `:endpoint` and
    `:actor_resource` are read with `Application.compile_env/2` — resources bake
    them in as they compile — so this belongs here and not in `runtime.exs`.
    """

    @css_path "assets/css/app.css"
    @css_source ~s|@source "../../deps/ash_quick/lib/**/*.*ex";|

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        example: @example,
        schema: [
          actor_resource: :string,
          audit_resource: :string,
          timezone: :string
        ],
        defaults: [timezone: "Etc/UTC"],
        composes: ["ash.gen.domain", "ash.codegen"]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options

      {igniter, router} = Igniter.Libs.Phoenix.select_router(igniter)
      {igniter, endpoint} = Igniter.Libs.Phoenix.select_endpoint(igniter, router)
      {igniter, actor_resource} = select_actor_resource(igniter, options)
      {igniter, repo} = select_repo(igniter)

      web_module = Igniter.Libs.Phoenix.web_module(igniter)
      nav = Module.concat(web_module, Nav)
      access_control = Module.concat(web_module, AccessControl)
      audit_resource = audit_resource(igniter, options)

      igniter
      # First, so every file written below is formatted against the DSL's
      # `locals_without_parens` rather than with parentheses around `defaults`
      # and `enabled?`.
      |> Igniter.Project.Formatter.import_dep(:ash_quick)
      |> generate_audit_store(audit_resource, actor_resource, repo)
      |> generate_module(access_control, "access_control.ex.eex",
        module: access_control,
        nav: nav
      )
      |> generate_module(nav, "nav.ex.eex",
        module: nav,
        router: router,
        access_control: access_control
      )
      |> configure(endpoint, actor_resource, audit_resource, nav, web_module, options)
      |> configure_section_order()
      |> import_router_macro(router)
      |> Igniter.Project.Application.add_new_child(AshQuick.BrowserSessionPresence,
        after: [Phoenix.PubSub]
      )
      |> source_library_classes()
      |> Ash.Igniter.codegen("install_ash_quick")
      |> Igniter.add_notice(client_notice())
    end

    # The store is generated rather than shipped, because a project will add
    # columns to it. Skipped outright when the module is already there: a second
    # run of the installer must not claim to have written one.
    defp generate_audit_store(igniter, resource, actor_resource, repo) do
      domain = domain_of(resource)

      case Igniter.Project.Module.module_exists(igniter, resource) do
        {true, igniter} ->
          igniter

        {false, igniter} ->
          igniter
          |> Igniter.compose_task("ash.gen.domain", [inspect(domain), "--ignore-if-exists"])
          |> Igniter.copy_template(
            template("ash_quick.install", "audit_log.ex.eex"),
            Igniter.Project.Module.proper_location(igniter, resource),
            [module: resource, domain: domain, actor_resource: actor_resource, repo: repo],
            on_exists: :skip
          )
          |> Ash.Domain.Igniter.add_resource_reference(domain, resource)
          |> maybe_warn_data_layer(resource, repo)
      end
    end

    defp maybe_warn_data_layer(igniter, _resource, repo) when not is_nil(repo), do: igniter

    defp maybe_warn_data_layer(igniter, resource, _repo) do
      Igniter.add_warning(igniter, """
      #{inspect(resource)} was generated without a data layer, because this \
      project has no Ecto repo to point one at.

      As it stands the audit trail is not persisted anywhere. Give it a data \
      layer before relying on the log.
      """)
    end

    defp generate_module(igniter, module, template, assigns) do
      case Igniter.Project.Module.module_exists(igniter, module) do
        {true, igniter} ->
          igniter

        {false, igniter} ->
          Igniter.copy_template(
            igniter,
            template("ash_quick.install", template),
            Igniter.Project.Module.proper_location(igniter, module),
            assigns,
            on_exists: :skip
          )
      end
    end

    defp configure(igniter, endpoint, actor_resource, audit_resource, nav, web_module, options) do
      {igniter, translator} = error_translator(igniter, web_module)

      items =
        [
          {[:endpoint], endpoint},
          {[:actor_resource], actor_resource},
          {[:audit_resource], audit_resource},
          {[:nav], nav},
          {[:error_translator], translator},
          {[:timezone], options[:timezone]}
        ]
        |> Enum.reject(fn {_path, value} -> is_nil(value) end)

      Igniter.Project.Config.configure_group(igniter, "config.exs", :ash_quick, [], items,
        comment: @config_comment
      )
    end

    # `translate_error/1` is where a host's changeset errors become the strings
    # a form renders, and every Phoenix application already has one. Left unset
    # when it does not, rather than configured at a module that is not there.
    defp error_translator(igniter, web_module) do
      core_components = Module.concat(web_module, CoreComponents)

      case Igniter.Project.Module.module_exists(igniter, core_components) do
        {true, igniter} -> {igniter, {core_components, :translate_error}}
        {false, igniter} -> {igniter, nil}
      end
    end

    defp configure_section_order(igniter) do
      Igniter.Project.Config.configure(
        igniter,
        "config.exs",
        :spark,
        [:formatter, :"Ash.Resource", :section_order],
        @section_order,
        updater: &add_section/1
      )
    end

    defp add_section(zipper) do
      case section_names(zipper) do
        {:ok, names} ->
          if :ash_quick in names do
            {:ok, zipper}
          else
            {:ok, Igniter.Code.Common.replace_code(zipper, before_pub_sub(names))}
          end

        # An order built out of anything but plain atoms — a module attribute,
        # a concatenation — is not ours to rewrite. Appending leaves
        # `:ash_quick` below `:pub_sub`, which only misplaces a hand-written
        # `pub_sub` block on a resource that has one.
        :error ->
          Igniter.Code.List.append_new_to_list(zipper, :ash_quick)
      end
    end

    defp section_names(zipper) do
      with {:ok, items} <- items(Sourceror.Zipper.node(zipper)),
           true <- Enum.all?(items, &named?/1) do
        {:ok, Enum.map(items, &name/1)}
      else
        _other -> :error
      end
    end

    # Sourceror wraps a literal in a `__block__` to hang its formatting off, and
    # whether this zipper is at the wrapper or at the list itself depends on how
    # the order was written.
    defp items({:__block__, _meta, [items]}) when is_list(items), do: {:ok, items}
    defp items(items) when is_list(items), do: {:ok, items}
    defp items(_other), do: :error

    defp named?(item), do: not is_nil(name(item))

    defp name({:__block__, _meta, [name]}) when is_atom(name), do: name
    defp name(name) when is_atom(name), do: name
    defp name(_other), do: nil

    defp before_pub_sub(names) do
      {above, below} = Enum.split_while(names, &(&1 != :pub_sub))
      above ++ [:ash_quick] ++ below
    end

    defp import_router_macro(igniter, nil) do
      Igniter.add_warning(igniter, """
      No Phoenix router was found, so `import AshQuick.LiveView.Router` was not \
      added anywhere.

      Add it to the router that will serve the QuickViews: `quick_view/3` comes \
      from there, and a QuickView routed with a plain `live/3` has no base path \
      to build its links from.
      """)
    end

    defp import_router_macro(igniter, router) do
      Igniter.Project.Module.find_and_update_module!(igniter, router, fn zipper ->
        if imports_router?(zipper) do
          {:ok, zipper}
        else
          {:ok, add_import(igniter, zipper)}
        end
      end)
    end

    defp imports_router?(zipper) do
      match?(
        {:ok, _zipper},
        Igniter.Code.Function.move_to_function_call_in_current_scope(
          zipper,
          :import,
          1,
          fn call ->
            Igniter.Code.Function.argument_equals?(call, 0, AshQuick.LiveView.Router)
          end
        )
      )
    end

    defp add_import(igniter, zipper) do
      import_code = "import AshQuick.LiveView.Router"

      case Igniter.Libs.Phoenix.move_to_router_use(igniter, zipper) do
        {:ok, zipper} -> Igniter.Code.Common.add_code(zipper, import_code, placement: :after)
        :error -> Igniter.Code.Common.add_code(zipper, import_code)
      end
    end

    # Without this every QuickView renders unstyled: the library's classes live
    # in its own `lib/`, which a host's Tailwind build does not scan.
    defp source_library_classes(igniter) do
      if Igniter.exists?(igniter, @css_path) do
        Igniter.update_file(igniter, @css_path, &append_source/1)
      else
        Igniter.add_warning(igniter, """
        #{@css_path} was not found, so AshQuick's classes are not in the \
        Tailwind build. Without them every QuickView renders unstyled. Add to \
        wherever this project's CSS entrypoint lives:

            #{@css_source}
        """)
      end
    end

    defp append_source(source) do
      content = Rewrite.Source.get(source, :content)

      if String.contains?(content, "deps/ash_quick") do
        source
      else
        Rewrite.Source.update(
          source,
          :content,
          """
          #{String.trim_trailing(content)}

          /* AshQuick's classes live in its own lib/, which this build would not scan. */
          #{@css_source}
          """
        )
      end
    end

    defp select_actor_resource(igniter, options) do
      case options[:actor_resource] do
        nil ->
          {igniter, candidates} =
            Igniter.Project.Module.find_all_matching_modules(igniter, &actor_shaped?/2)

          {igniter,
           Igniter.Util.IO.select("Which resource is an audited write's actor?", candidates,
             display: &inspect/1
           )}

        name ->
          {igniter, Igniter.Project.Module.parse(name)}
      end
    end

    # A guess, offered for confirmation rather than taken: the resource behind
    # `created_by` has to be the one an authenticated request already carries,
    # and only the application knows that. Read off the project's files rather
    # than its compiled domains, so a resource that has not been registered in
    # one yet is still offered.
    defp actor_shaped?(module, zipper) do
      List.last(Module.split(module)) in ~w(User Account Actor Member Person) and
        match?({:ok, _zipper}, Igniter.Code.Module.move_to_use(zipper, Ash.Resource))
    end

    # Only with AshPostgres: the store's table, its indexes and its refusal to
    # let an actor be deleted are all data-layer declarations, and a repo behind
    # some other data layer would take none of them.
    defp select_repo(igniter) do
      if Igniter.Project.Deps.has_dep?(igniter, :ash_postgres) do
        Igniter.Libs.Ecto.select_repo(igniter, label: "Which repo should the audit store use?")
      else
        {igniter, nil}
      end
    end

    defp audit_resource(igniter, options) do
      case options[:audit_resource] do
        nil -> Igniter.Project.Module.module_name(igniter, "AuditLogs.AuditLog")
        name -> Igniter.Project.Module.parse(name)
      end
    end

    defp domain_of(resource) do
      resource |> Module.split() |> Enum.drop(-1) |> Module.concat()
    end

    defp template(task, name) do
      :ash_quick |> Application.app_dir("priv/templates") |> Path.join(task) |> Path.join(name)
    end

    # The client half is structural rather than a line to append — the params
    # have to become a function, so every reconnect re-reads the tab's identity
    # — so it is stated rather than patched in.
    defp client_notice do
      """
      One step left, in `assets/js/app.js`:

          import { browserSessionParams, initBrowserSession } from "../../deps/ash_quick/assets/js/browser_session"
          import { initLocale } from "../../deps/ash_quick/assets/js/locale"

          let liveSocket = new LiveSocket("/live", Socket, {
            // A function, so every reconnect re-reads the tab's identity.
            params: () => ({ _csrf_token: csrfToken, ...browserSessionParams() }),
            hooks: hooks
          })

          initBrowserSession(liveSocket)
          initLocale()

      `browserSessionParams` is the id a tab mints for itself and replays on
      every connect — the unit `AshQuick.BrowserSessionPresence` registers, and
      the one an impersonation is revoked at. `initLocale` applies the `lang`
      and `dir` the connected mount pushes.

      Then put `AshQuick.LiveView.Mount` first in the `on_mount` of the
      live_session serving the QuickViews, and route one with
      `mix ash_quick.gen.quick_view`.
      """
    end
  end
else
  defmodule Mix.Tasks.AshQuick.Install do
    @shortdoc "Configures AshQuick and generates the audit store, the nav and the access control"

    @moduledoc @shortdoc

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_quick.install' requires igniter to be run.

      Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter
      """)

      exit({:shutdown, 1})
    end
  end
end
