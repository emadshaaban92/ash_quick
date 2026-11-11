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
      * Writes `config :tower, reporters: [Tower.EphemeralReporter]` into
        `config/config.exs`, as a placeholder to replace: the errors a page
        could not explain are reported through Tower, and that reporter keeps
        them in memory only. Left alone when the project already sets Tower's
        `:reporters`.
      * Generates the audit store, its domain and its migration. Generated into
        the application rather than shipped as a library resource, because
        projects add columns to it.
      * Generates a starter `AccessControl` and a `Nav`, the two modules the
        sidebar and the apps grid are rendered from.
      * Imports `AshQuick.LiveView.Router` into the router, since a QuickView
        reached through a plain `live/3` has no base path and says so at request
        time.
      * Adds `:ash_quick` to `import_deps` and to Spark's `section_order`.
      * Adds `AshQuick` to the application's supervision tree, after the
        PubSub server, or puts it in place of `AshQuick.BrowserSessionPresence`
        where an earlier setup listed that, and points the Tailwind build at
        the library's own classes.
      * Adds the `phx-submit-loading` Tailwind variant when `app.css` lacks it,
        which the action modal's spinner and lock hang on.
      * Passes the LiveSocket's options in `app.js` through `withAshQuick`
        (the library's hooks, its `S3` client uploader and the tab's session
        params) and attaches the socket with `attachAshQuick` (its listeners
        for impersonation, the page's locale and printed PDFs).

    Writing the templates the host translates Ash's error messages and
    AshQuick in (`mix ash.gen.gettext`, `mix ash_quick.gen.gettext`), which
    write into `priv/gettext`, is stated in a notice rather than done.

    ## Options

      * `--actor-resource` - The resource a record's `inserted_by` / `updated_by`
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

    @tower_comment """
    AshQuick reports every error a page could not explain through Tower. This
    reporter is Tower's default, and keeps them only in memory: name one that
    delivers them. https://hexdocs.pm/tower/Tower.html#module-reporters
    """
    @tower_comment_first_line @tower_comment |> String.split("\n") |> hd()

    @css_path "assets/css/app.css"
    @css_source ~s|@source "../../deps/ash_quick/lib/**/*.*ex";|
    @css_submit_loading ~s|@custom-variant phx-submit-loading (.phx-submit-loading&, .phx-submit-loading &);|
    @js_path "assets/js/app.js"
    @js_import ~s|import {withAshQuick, attachAshQuick} from "ash_quick"|

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
      |> configure_error_reporting()
      |> import_router_macro(router)
      |> supervise_library()
      |> source_library_classes()
      |> import_library_live_socket()
      |> Ash.Igniter.codegen("install_ash_quick")
      |> Igniter.add_notice(mount_notice())
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
      {igniter, backend} = gettext_backend(igniter, web_module)

      items =
        [
          {[:endpoint], endpoint},
          {[:actor_resource], actor_resource},
          {[:audit_resource], audit_resource},
          {[:nav], nav},
          {[:gettext], backend},
          {[:error_translator], translator},
          {[:timezone], options[:timezone]}
        ]
        |> Enum.reject(fn {_path, value} -> is_nil(value) end)

      igniter
      |> Igniter.Project.Config.configure_group("config.exs", :ash_quick, [], items,
        comment: @config_comment
      )
      |> maybe_add_gettext_notice(translator)
      |> maybe_add_template_notice(backend)
      |> maybe_add_localize_notice(backend)
    end

    # Copying Ash's messages writes into the host's `priv/gettext`, which is
    # theirs to run when they want it, so it is stated rather than run. Only
    # with a translator: without one there is nothing to translate them through.
    defp maybe_add_gettext_notice(igniter, nil), do: igniter

    defp maybe_add_gettext_notice(igniter, {module, function}) do
      Igniter.add_notice(igniter, """
      To translate Ash's own error messages, copy them into your catalogue:

          mix ash.gen.gettext --domain errors
          mix gettext.merge priv/gettext

      AshQuick renders them through `#{inspect(module)}.#{function}/1`, the
      `:error_translator` written above, in a flash as well as next to an input;
      `--domain errors` puts them where its `dgettext(..., "errors", ...)` looks.
      """)
    end

    # Writing the template writes into the host's `priv/gettext` too, so it is
    # stated the same way. Only with a backend: without one AshQuick is English.
    defp maybe_add_template_notice(igniter, nil), do: igniter

    defp maybe_add_template_notice(igniter, backend) do
      Igniter.add_notice(igniter, """
      To translate AshQuick, its own strings and the labels your pages draw,
      write its template into #{inspect(backend)}'s catalogue:

          mix ash_quick.gen.gettext
          mix gettext.merge priv/gettext

      `--locale ar` also copies the Arabic translation AshQuick ships. Run it
      again when you add a field, an action or a nav entry; `--check` fails CI
      until you do.
      """)
    end

    # Downloading writes into the host's build, so it is stated too. Only with a
    # backend: a host that translates nothing reads English dates already.
    defp maybe_add_localize_notice(igniter, nil), do: igniter

    defp maybe_add_localize_notice(igniter, backend) do
      locales =
        case gettext_locales() do
          [] -> "[:en, :ar]  # for example: the locales #{inspect(backend)} has"
          found -> inspect(found)
        end

      Igniter.add_notice(igniter, """
      AshQuick formats dates, times and money with Localize, in the locale
      #{inspect(backend)} translates in. Localize ships English data alone, and a
      locale it has no data for reads in English. List the locales your backend
      has in config/config.exs (the download task reads that file alone, before
      anything is compiled):

          config :localize,
            otp_app: #{inspect(Igniter.Project.Application.app_name(igniter))},
            supported_locales: #{locales}

      and download their data when you build:

          mix localize.download_locales
      """)
    end

    # The locales with a catalogue under the backend's default priv, as Gettext
    # finds them, read off the host's disk: a catalogue is not Elixir, so
    # Igniter does not load it.
    defp gettext_locales do
      "priv/gettext/*/LC_MESSAGES"
      |> Path.wildcard()
      |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
      |> Enum.sort()
    end

    # There is no reporter to default to: each one that delivers anywhere is a
    # package of its own. So the placeholder is Tower's own default, written out
    # where the host will edit it — and what `mix ash_quick.check` reports until
    # they do. A reporter set in any of the files that would win over this one
    # is the host's, and gets neither the placeholder nor the notice.
    defp configure_error_reporting(igniter) do
      if Enum.any?(~w(config.exs prod.exs runtime.exs), &configures_reporters?(igniter, &1)) do
        igniter
      else
        igniter
        |> Igniter.Project.Config.configure(
          "config.exs",
          :tower,
          [:reporters],
          [Tower.EphemeralReporter],
          updater: &{:ok, &1}
        )
        |> Igniter.update_file("config/config.exs", &comment_reporters/1)
        |> Igniter.add_notice(reporter_notice())
      end
    end

    # Put into the text rather than through `configure_group/6`'s `:comment`,
    # which Igniter hangs on whichever node it lands beside when another
    # commented group was added to the same file in the same run.
    defp comment_reporters(source) do
      content = Rewrite.Source.get(source, :content)
      placeholder = ~r/^([ \t]*)(config :tower,.*Tower\.EphemeralReporter)/m

      if String.contains?(content, @tower_comment_first_line) do
        source
      else
        Rewrite.Source.update(
          source,
          :content,
          Regex.replace(placeholder, content, &comment_above/3, global: false)
        )
      end
    end

    defp comment_above(_match, indent, line) do
      comment =
        @tower_comment
        |> String.split("\n", trim: true)
        |> Enum.map_join(&"#{indent}# #{&1}\n")

      comment <> indent <> line
    end

    defp configures_reporters?(igniter, file),
      do: Igniter.Project.Config.configures_key?(igniter, file, :tower, :reporters)

    # `translate_error/1` is where a host's changeset errors become the strings
    # a form renders, and every Phoenix application already has one. Left unset
    # when it does not, rather than configured at a module that is not there.
    defp error_translator(igniter, web_module) do
      case web_module(igniter, web_module, CoreComponents) do
        {igniter, nil} -> {igniter, nil}
        {igniter, core_components} -> {igniter, {core_components, :translate_error}}
      end
    end

    # Every Phoenix application has a Gettext backend; AshQuick translates
    # through it. Left unset when there is none, and AshQuick draws English.
    defp gettext_backend(igniter, web_module), do: web_module(igniter, web_module, Gettext)

    # `<Web>.<suffix>` when the application has it, else nil.
    defp web_module(igniter, web_module, suffix) do
      module = Module.concat(web_module, suffix)

      case Igniter.Project.Module.module_exists(igniter, module) do
        {true, igniter} -> {igniter, module}
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
            #{@css_submit_loading}
        """)
      end
    end

    defp append_source(source) do
      content = Rewrite.Source.get(source, :content)

      additions =
        [
          {"deps/ash_quick",
           """
           /* AshQuick's classes live in its own lib/, which this build would not scan. */
           #{@css_source}
           """},
          # A new Phoenix app defines this already. Without it an action modal
          # shows no spinner and its controls stay live while the action runs.
          {"@custom-variant phx-submit-loading",
           """
           /* Styles a form, and what is in it, while LiveView waits on its submit. */
           #{@css_submit_loading}
           """}
        ]
        |> Enum.reject(fn {present, _addition} -> String.contains?(content, present) end)
        |> Enum.map(fn {_present, addition} -> addition end)

      if additions == [] do
        source
      else
        Rewrite.Source.update(
          source,
          :content,
          Enum.join([String.trim_trailing(content) <> "\n" | additions], "\n")
        )
      end
    end

    # `AshQuick` starts the register itself, so a tree still naming it beside
    # `AshQuick` fails to boot with `already_started`. Renamed in place, which
    # keeps its position and any `pubsub_server:` it was given; `add_new_child`
    # then finds `AshQuick` there and adds nothing. The lookahead leaves calls
    # such as `AshQuick.BrowserSessionPresence.revoke/1` alone.
    @presence_child ~r/\bAshQuick\.BrowserSessionPresence\b(?!\.)/

    # An alias means the tree may name the register by its short name, which
    # no rename of the long one would reach.
    @presence_alias ~r/\balias\s+AshQuick\.(BrowserSessionPresence\b|\{[^}]*\bBrowserSessionPresence\b)/

    defp supervise_library(igniter) do
      path = Igniter.Project.Module.proper_location(igniter, application_module(igniter))

      igniter =
        if Igniter.exists?(igniter, path),
          do: Igniter.include_existing_file(igniter, path),
          else: igniter

      content = application_content(igniter, path)

      cond do
        content && Regex.match?(@presence_alias, content) ->
          Igniter.add_warning(igniter, presence_alias_instructions(path))

        content && Regex.match?(@presence_child, content) ->
          igniter
          |> Igniter.update_file(path, fn source ->
            Rewrite.Source.update(
              source,
              :content,
              Regex.replace(@presence_child, content, "AshQuick")
            )
          end)
          |> Igniter.Project.Application.add_new_child(AshQuick, after: [Phoenix.PubSub])

        true ->
          Igniter.Project.Application.add_new_child(igniter, AshQuick, after: [Phoenix.PubSub])
      end
    end

    defp application_content(igniter, path) do
      case Rewrite.source(igniter.rewrite, path) do
        {:ok, source} -> Rewrite.Source.get(source, :content)
        _ -> nil
      end
    end

    defp presence_alias_instructions(path) do
      """
      #{path} aliases `AshQuick.BrowserSessionPresence`, so AshQuick was not \
      added to the supervision tree: the tree may already start the register \
      by its short name, and `AshQuick` starts it too, which fails to boot \
      with `already_started`. Replace the register's entry with `AshQuick`, \
      keeping any `pubsub_server:` it was given:

          children = [
            {Phoenix.PubSub, name: MyApp.PubSub},
            AshQuick,
            MyAppWeb.Endpoint
          ]
      """
    end

    # The module `add_new_child/3` writes to: the one `mix.exs` names under
    # `mod:`, or `<App>.Application` when it names none.
    defp application_module(igniter) do
      case Igniter.Project.Application.app_module(igniter) do
        nil -> Igniter.Project.Module.module_name(igniter, "Application")
        {module, _args} -> module
        module -> module
      end
    end

    # The host keeps Phoenix's LiveSocket: its options go through
    # `withAshQuick` and the socket is attached once built. Patched where the
    # script is the shape Phoenix generates (`<const|let|var> name = new
    # LiveSocket(url, Socket, options)`); anything else gets instructions.
    defp import_library_live_socket(igniter) do
      if Igniter.exists?(igniter, @js_path) do
        Igniter.update_file(igniter, @js_path, &use_library_live_socket/1)
      else
        Igniter.add_warning(igniter, live_socket_instructions("#{@js_path} was not found"))
      end
    end

    @live_view_import ~r/^import\s*\{[^}]*\bLiveSocket\b[^}]*\}\s*from\s*["']phoenix_live_view["'];?[ \t]*$/m
    @live_socket_call ~r/\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*new\s+LiveSocket\s*\(/

    defp use_library_live_socket(source) do
      content = Rewrite.Source.get(source, :content)

      cond do
        Regex.match?(~r/from\s*["']ash_quick["']/, content) ->
          source

        # The hand-written setup these replace. Patching beside it would
        # register every listener twice.
        String.contains?(content, "deps/ash_quick/assets/js") or
            String.contains?(content, "phoenix-colocated/ash_quick") ->
          {:warning, earlier_setup_instructions()}

        true ->
          case wrap_live_socket(content) do
            {:ok, content} -> Rewrite.Source.update(source, :content, content)
            {:error, reason} -> {:warning, live_socket_instructions(reason)}
          end
      end
    end

    defp wrap_live_socket(content) do
      with {:import, [{import_at, import_length}]} <-
             {:import, Regex.run(@live_view_import, content, return: :index)},
           {:call, [{call_at, call_length}, {name_at, name_length}]} <-
             {:call, Regex.run(@live_socket_call, content, return: :index)},
           args_at = call_at + call_length,
           {:args, {:ok, args, close_at}} <- {:args, call_arguments(content, args_at)},
           {:options, [_url, _socket, {options_at, options_end}]} <- {:options, args},
           import_end = import_at + import_length,
           {:order, true} <- {:order, import_end < call_at} do
        name = binary_part(content, name_at, name_length)
        statement_end = statement_end(content, close_at + 1)
        # The host's own style: a semicolon after the call means one after ours.
        semicolon = if binary_part(content, statement_end - 1, 1) == ";", do: ";", else: ""

        content =
          content
          |> splice(statement_end, 0, "\nattachAshQuick(#{name})#{semicolon}")
          |> splice(options_end, 0, ")")
          |> splice(options_at, 0, "withAshQuick(")
          |> splice(import_end, 0, "\n" <> @js_import)

        {:ok, content}
      else
        {:import, _} ->
          {:error, ~s|#{@js_path} does not import `LiveSocket` from "phoenix_live_view"|}

        _ ->
          {:error,
           "#{@js_path} does not build its socket as " <>
             "`const liveSocket = new LiveSocket(url, Socket, options)`"}
      end
    end

    defp splice(content, at, drop, insert) do
      <<head::binary-size(^at), _::binary-size(^drop), rest::binary>> = content
      head <> insert <> rest
    end

    # The call's top-level arguments as `{start, end}` byte ranges, trimmed,
    # and the offset of its closing parenthesis. Skips strings, template
    # literals and comments, so a bracket inside one is not counted.
    defp call_arguments(content, from) do
      scan_arguments(content, from, from, 0, [])
    end

    defp scan_arguments(content, at, arg_start, depth, args) when at < byte_size(content) do
      case token(content, at) do
        {:skip, next} ->
          scan_arguments(content, next, arg_start, depth, args)

        :open ->
          scan_arguments(content, at + 1, arg_start, depth + 1, args)

        :close when depth == 0 ->
          {:ok, Enum.reverse(add_argument(content, arg_start, at, args)), at}

        :close ->
          scan_arguments(content, at + 1, arg_start, depth - 1, args)

        :comma when depth == 0 ->
          scan_arguments(
            content,
            at + 1,
            at + 1,
            depth,
            add_argument(content, arg_start, at, args)
          )

        _other ->
          scan_arguments(content, at + 1, arg_start, depth, args)
      end
    end

    defp scan_arguments(_content, _at, _arg_start, _depth, _args), do: :error

    defp token(content, at) do
      case binary_part(content, at, 1) do
        quote when quote in ["\"", "'", "`"] -> {:skip, skip_string(content, at + 1, quote)}
        "/" -> comment(content, at)
        open when open in ["(", "[", "{"] -> :open
        close when close in [")", "]", "}"] -> :close
        "," -> :comma
        _other -> :other
      end
    end

    defp comment(content, at) do
      case binary_part(content, at, min(2, byte_size(content) - at)) do
        "//" -> {:skip, skip_until(content, at, "\n")}
        "/*" -> {:skip, skip_until(content, at, "*/") + 2}
        _other -> :other
      end
    end

    # A trailing comma leaves an empty last argument, which is not one.
    defp add_argument(content, from, to, args) do
      text = binary_part(content, from, to - from)
      leading = byte_size(text) - byte_size(String.trim_leading(text))
      trimmed = String.trim(text)

      if trimmed == "",
        do: args,
        else: [{from + leading, from + leading + byte_size(trimmed)} | args]
    end

    defp skip_string(content, at, quote) do
      cond do
        at >= byte_size(content) -> at
        binary_part(content, at, 1) == "\\" -> skip_string(content, at + 2, quote)
        binary_part(content, at, 1) == quote -> at + 1
        true -> skip_string(content, at + 1, quote)
      end
    end

    defp skip_until(content, at, marker) do
      <<_::binary-size(^at), rest::binary>> = content

      case :binary.match(rest, marker) do
        {found, _} -> at + found
        :nomatch -> byte_size(content)
      end
    end

    # The end of the line the call's closing parenthesis is on.
    defp statement_end(content, at) do
      <<_::binary-size(^at), rest::binary>> = content

      case :binary.match(rest, "\n") do
        {newline, _} -> at + newline
        :nomatch -> byte_size(content)
      end
    end

    defp live_socket_instructions(reason) do
      """
      #{reason}, so AshQuick is not wired into the LiveSocket. Without it \
      the action modal's controls still answer the keyboard while an action \
      runs, a file picked for an attachment is never uploaded, impersonation \
      never starts and printed PDFs never arrive. Add:

          #{@js_import}

          const liveSocket = new LiveSocket("/live", Socket, withAshQuick({
            // your options, unchanged
          }))
          attachAshQuick(liveSocket)
      """
    end

    defp earlier_setup_instructions do
      """
      #{@js_path} sets AshQuick up by hand: it imports from \
      "deps/ash_quick/assets/js" or "phoenix-colocated/ash_quick". Replace all \
      of that with:

          #{@js_import}

          const liveSocket = new LiveSocket("/live", Socket, withAshQuick({
            // your options, without the AshQuick parts below
          }))
          attachAshQuick(liveSocket)

      dropping `browserSessionParams()` from the params, `ashQuickHooks` and \
      `ashQuickUploaders` from the hooks and uploaders, and the \
      `initBrowserSession`, `initLocale` and `initPrinting` calls.
      """
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
    # `inserted_by` has to be the one an authenticated request already carries,
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

    defp reporter_notice do
      """
      Name an error reporter in `config/config.exs`:

          config :tower, reporters: [TowerSentry]

      The errors a page could not explain are reported through Tower, and the
      reporter written there for now, `Tower.EphemeralReporter`, keeps them in
      memory and sends them nowhere. Every reporter that delivers them is a
      package of its own: https://hexdocs.pm/tower/Tower.html#module-reporters.
      Until one is named, `mix ash_quick.check` reports
      `unconfigured_error_reporter`.
      """
    end

    defp mount_notice do
      """
      Put `AshQuick.LiveView.Mount` first in the `on_mount` of the
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
