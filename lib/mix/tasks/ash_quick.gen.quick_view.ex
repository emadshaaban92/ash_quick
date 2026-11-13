if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshQuick.Gen.QuickView do
    @example "mix ash_quick.gen.quick_view MyApp.Catalog.Product"

    @shortdoc "Generates a QuickView over a resource, routes it, and grants the route"

    @moduledoc """
    Generates a QuickView over an existing resource.

    ```bash
    #{@example}
    ```

    Writes three things, which is what it takes for the page to be reachable:

      * `MyAppWeb.ProductLive.Quick`, with a starter field list taken from the
        resource's public attributes — its own columns, without the ones
        AshQuick generated. Trim it; the generator cannot know which three of
        twenty columns a list is read for. The file goes where the QuickViews
        the router already serves are, laid out the way theirs are and in a
        directory of its own; with none routed yet, it goes where Igniter puts
        the module's name.
      * One `quick_view/3` line in the router, placed with the QuickViews that
        are already there or in the live_session running
        `AshQuick.LiveView.Mount`. A resource with no `:create` action is routed
        `except: [:create]`, which is what keeps something the system creates
        out of the "New" flow.
      * The path, in the application's `AshQuick.AccessControl`. Without it the
        route exists and every navigation to it is refused. The path is added
        to the module's `@routes` list, or with `--grant-to` to the clause of
        each role named.

    The sidebar needs nothing further: a QuickView is discovered from its route.
    A tile in the apps grid is a `group` in the nav, which is a decision about
    where the page belongs rather than one this task can make.

    ## Options

      * `--path` - The base path to serve it at. Defaults to the resource's
        `plural_name`.
      * `--module` - The QuickView module. Defaults to
        `MyAppWeb.<Resource>Live.Quick`.
      * `--file` - The file to write it to, when not the one the routed
        QuickViews point to. A custom `action_<name>.html.heex` template applies
        to every QuickView in its directory, so a directory another QuickView
        already sits in is warned about.
      * `--grant-to` - Roles to grant the path to, comma separated, for an
        access control that lists its routes per role:

            def routes_for_role(:admin), do: ~w(/users)

        The path is added to the list of the clause matching `:admin`
        literally, when that list is a literal list or `~w(...)`. The clauses
        read are those of the function `routes_for/1` hands the role to, or of
        `routes_for_role/1` when it calls none.
        A role with no such clause is reported, and left for you to grant.
    """

    use Igniter.Mix.Task

    alias Sourceror.Zipper

    # The columns AshQuick generates rather than the ones the resource is about.
    # `:id` addresses the row and is already the link; `:version` is the
    # optimistic lock; the bookkeeping four are on the details page by way of
    # its own header.
    @generated [:id, :version]

    # Enough to recognise a record by, and few enough that the list is readable
    # on the first load. The rest is a decision, and a decision left in a
    # generated file is one nobody makes.
    @list_limit 8

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        example: @example,
        positional: [:resource],
        schema: [path: :string, module: :string, file: :string, grant_to: :csv]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      resource = Igniter.Project.Module.parse(igniter.args.positional.resource)

      case validate(resource, igniter.args.options) do
        :ok -> generate(igniter, resource)
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    # The field list is read off the compiled resource, so the resource has to
    # be one: a name that resolves to nothing, or to a module that never took
    # the extension, is reported as itself rather than as a page that renders
    # a label of `nil`.
    defp validate(resource, options) do
      cond do
        options[:file] && Path.extname(options[:file]) != ".ex" ->
          {:error, "--file names the module's source file, and has to end in `.ex`."}

        not match?({:module, _module}, Code.ensure_compiled(resource)) ->
          {:error,
           """
           #{inspect(resource)} does not exist.

           A QuickView is generated from the resource's own attributes, so the \
           resource has to be there first. `mix ash.gen.resource` generates one.
           """}

        not Ash.Resource.Info.resource?(resource) ->
          {:error, "#{inspect(resource)} is not an Ash resource."}

        not extended?(resource) ->
          {:error,
           """
           #{inspect(resource)} does not carry the AshQuick extension.

           A QuickView over a resource without it has no display label, no \
           publications and no audit trail — the page looks healthy and is not. \
           Add the extension first:

               mix ash_quick.gen.resource #{inspect(resource)}
           """}

        true ->
          :ok
      end
    end

    defp extended?(resource) do
      AshQuick in Spark.extensions(resource)
    end

    defp generate(igniter, resource) do
      options = igniter.args.options

      module = module(igniter, resource, options)
      path = path(resource, options)
      {igniter, router} = Igniter.Libs.Phoenix.select_router(igniter)

      igniter
      |> generate_module(module, resource, router, path)
      |> add_route(router, path, module, resource)
      |> grant_route(path, roles(options[:grant_to]))
    end

    # `--grant-to :admin` names the same role as `--grant-to admin`.
    defp roles(nil), do: []

    defp roles(roles),
      do: roles |> Enum.map(&String.trim_leading(&1, ":")) |> Enum.reject(&(&1 == ""))

    defp generate_module(igniter, module, resource, router, path) do
      case Igniter.Project.Module.module_exists(igniter, module) do
        {true, igniter} ->
          Igniter.add_warning(igniter, "#{inspect(module)} already exists; left as it is.")

        {false, igniter} ->
          {igniter, file} = location(igniter, module, resource, router, path)
          write_module(igniter, file, module, resource)
      end
    end

    defp write_module(igniter, file, module, resource) do
      list = fields(resource)
      details = list ++ (AshQuick.Info.timestamp_fields(resource) -- list)

      # An issue rather than a warning: the route and the grant would otherwise
      # be written for a module that never was.
      if Igniter.exists?(igniter, file) do
        Igniter.add_issue(igniter, """
        #{file} already exists, so #{inspect(module)} cannot be written there. \
        Name another file with `--file`.
        """)
      else
        igniter
        |> Igniter.copy_template(
          :ash_quick
          |> Application.app_dir("priv/templates/ash_quick.gen.quick_view")
          |> Path.join("quick.ex.eex"),
          file,
          [
            module: module,
            resource: resource,
            list_fields: inspect(list),
            details_fields: inspect(details)
          ],
          on_exists: :skip
        )
        |> keep_in_place(file)
        |> warn_shared_directory(file, module)
      end
    end

    # Igniter moves a file it created to the place its module's name maps to
    # when it writes, which would undo the choice of where it goes.
    defp keep_in_place(igniter, file) do
      kept = [file | Igniter.Project.IgniterConfig.get(igniter, :dont_move_files)]
      config = Keyword.put(igniter.assigns[:igniter_exs] || [], :dont_move_files, kept)
      Igniter.assign(igniter, :igniter_exs, config)
    end

    # Where the file goes. A custom `action_<name>.html.heex` applies to every
    # QuickView in its directory, so this decides which templates the view
    # picks up as well as where a reader finds it: the QuickViews the router
    # already serves are where the host keeps them, and the new one is laid out
    # the way they are. Igniter's location for the module's name is for an
    # application with none yet.
    defp location(igniter, module, resource, router, path) do
      case igniter.args.options[:file] do
        nil ->
          case routed_layout(igniter, router) do
            {igniter, nil} ->
              {igniter, Igniter.Project.Module.proper_location(igniter, module)}

            {igniter, layout} ->
              {igniter, fill(layout, new_plural(path, resource), singular(resource))}
          end

        file ->
          {igniter, normalise(file)}
      end
    end

    # The route's last segment, or the resource's plural for a view served at
    # its scope's own path.
    defp new_plural(path, resource) do
      case plural(path) do
        "" -> resource |> singular() |> Igniter.Inflex.pluralize()
        plural -> plural
      end
    end

    # Igniter keeps its sources by their path relative to the project, and
    # `dont_move_files` compares paths as strings: `./lib/x.ex` and the
    # absolute spelling of it would otherwise be moved back.
    defp normalise(file), do: file |> Path.expand() |> Path.relative_to_cwd()

    # The layout most of the routed QuickViews share, as a path with the plural
    # and the singular of each view's resource taken out. A view whose source is
    # not in the project, such as one a dependency ships, says nothing about
    # where this project keeps its own, and neither does one only a test routes.
    defp routed_layout(igniter, nil), do: {igniter, nil}

    defp routed_layout(igniter, router) do
      {igniter, views} = routed_views(igniter, router)

      {igniter, layouts} =
        Enum.reduce(views, {igniter, []}, fn {module, route}, {igniter, layouts} ->
          case Igniter.Project.Module.find_module(igniter, module) do
            {:ok, {igniter, source, zipper}} ->
              {igniter, [view_layout(source, zipper, route) | layouts]}

            {:error, igniter} ->
              {igniter, layouts}
          end
        end)

      case layouts |> Enum.reject(&is_nil/1) |> Enum.reverse() do
        [] ->
          {igniter, nil}

        layouts ->
          counts = Enum.frequencies(layouts)
          {igniter, layouts |> Enum.uniq() |> Enum.max_by(&Map.fetch!(counts, &1))}
      end
    end

    defp view_layout(source, zipper, route) do
      file = Rewrite.Source.get(source, :path)

      route_plural = plural(route)
      singular = view_singular(zipper) || Igniter.Inflex.singularize(route_plural)

      # A view routed at its scope's own path has no last segment to offer, and
      # one whose resource is not written out there has nothing to read at all.
      unless "test" in Path.split(file) or singular == "" do
        plurals =
          [Igniter.Inflex.pluralize(singular), route_plural]
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        layout(file, plurals, singular)
      end
    end

    defp routed_views(igniter, router) do
      case Igniter.Project.Module.find_module(igniter, router) do
        {:ok, {igniter, _source, zipper}} ->
          views =
            zipper
            |> Zipper.find_all(&quick_view_node?/1)
            |> Enum.flat_map(&routed_view/1)

          {igniter, views}

        {:error, igniter} ->
          {igniter, []}
      end
    end

    defp routed_view(call) do
      with {:quick_view, _meta, [route, {:__aliases__, _, parts} | _]} <- Zipper.node(call),
           route when is_binary(route) <- literal(route) do
        [{Module.concat(scope_alias(call) ++ Enum.map(parts, &to_string/1)), route}]
      else
        _other -> []
      end
    end

    defp quick_view_node?({:quick_view, _meta, args}) when length(args) in [2, 3], do: true
    defp quick_view_node?(_node), do: false

    # The view's own `use` line names its resource; the module's name may not.
    defp view_singular(zipper) do
      {_tree, resource} =
        zipper
        |> Zipper.node()
        |> Macro.prewalk(nil, fn
          {:use, _, [{:__aliases__, _, [:AshQuick, :LiveView, :QuickView]}, options]} = node,
          nil ->
            {node, resource_option(options)}

          node, found ->
            {node, found}
        end)

      resource
    end

    defp resource_option(options) do
      Enum.find_value(List.wrap(literal(options)), fn
        {key, {:__aliases__, _, parts}} ->
          if literal(key) == :resource,
            do: parts |> List.last() |> to_string() |> Macro.underscore()

        _other ->
          nil
      end)
    end

    # Only the directory and the file name are read: those are what the layout
    # is made of, and a token matched in the application's own name above them
    # would be a coincidence. A file name that varies under a directory that
    # does not is a directory the views share, and the new one is given its own.
    #
    # A directory is read for the plural first and a file name for the
    # singular first, so a resource whose two are one word gives
    # `widgets/widget_quick.ex` rather than `widgets/widgets_quick.ex`.
    defp layout(file, plurals, singular) do
      case file |> Path.split() |> Enum.split(-2) do
        {parents, [directory, name]} ->
          directory = directory |> tokenize_plural(plurals) |> tokenize_singular(singular)
          name = name |> tokenize_singular(singular) |> tokenize_plural(plurals)

          cond do
            directory =~ "\0" -> Path.join(parents ++ [directory, name])
            name =~ "\0" -> Path.join(parents ++ [directory, "\0plural", name])
            true -> nil
          end

        _top_level ->
          nil
      end
    end

    # The resource's own plural before the route's, which may be named for
    # something else: `/entries` for a `LedgerEntry` kept in `ledger_entries/`.
    defp tokenize_plural(segment, plurals) do
      Enum.reduce(plurals, segment, &String.replace(&2, token(&1), "\0plural"))
    end

    defp tokenize_singular(segment, singular),
      do: String.replace(segment, token(singular), "\0singular")

    defp token(""), do: raise(ArgumentError, "an empty word matches everywhere")
    defp token(word), do: ~r/(?<![a-z0-9])#{Regex.escape(word)}(?![a-z0-9])/

    defp fill(layout, plural, singular) do
      layout
      |> String.replace("\0plural", plural)
      |> String.replace("\0singular", singular)
    end

    defp plural(route) do
      route |> String.split("/", trim: true) |> List.last("") |> String.replace("-", "_")
    end

    defp singular(resource) do
      resource |> Module.split() |> List.last() |> Macro.underscore()
    end

    defp literal({:__block__, _meta, [value]}), do: value
    defp literal(value), do: value

    defp warn_shared_directory(igniter, file, module) do
      directory = Path.dirname(file)
      igniter = Igniter.include_glob(igniter, Path.join(directory, "*.ex"))

      neighbours =
        igniter.rewrite
        |> Enum.filter(&(Path.dirname(Rewrite.Source.get(&1, :path)) == directory))
        |> Enum.reject(&(Rewrite.Source.get(&1, :path) == file))
        |> Enum.map(&Rewrite.Source.get(&1, :content))
        |> Enum.filter(&(&1 =~ "use AshQuick.LiveView.QuickView"))
        |> Enum.flat_map(&Regex.scan(~r/defmodule\s+([\w.]+)/, &1, capture: :all_but_first))
        |> List.flatten()

      case neighbours do
        [] ->
          igniter

        neighbours ->
          Igniter.add_warning(igniter, """
          #{inspect(module)} shares #{directory} with #{Enum.join(neighbours, ", ")}. \
          A custom `action_<name>.html.heex` there applies to every QuickView in \
          it, so each picks up the others' templates. Give it a directory of its \
          own with `--file` unless that is what you want.
          """)
      end
    end

    defp fields(resource) do
      skip =
        @generated ++
          AshQuick.Info.timestamp_fields(resource) ++ AshQuick.Info.actor_attributes(resource)

      resource
      |> Ash.Resource.Info.public_attributes()
      |> Enum.reject(& &1.sensitive?)
      |> Enum.map(& &1.name)
      |> Enum.reject(&(&1 in skip))
      |> Enum.take(@list_limit)
    end

    defp add_route(igniter, nil, path, module, _resource) do
      Igniter.add_warning(igniter, """
      No Phoenix router was found, so #{inspect(module)} is not routed. Add it \
      to the live_session that runs `AshQuick.LiveView.Mount`:

          quick_view "#{path}", #{inspect(module)}
      """)
    end

    defp add_route(igniter, router, path, module, resource) do
      Igniter.Project.Module.find_and_update_module!(igniter, router, fn zipper ->
        cond do
          routed?(zipper, path, module) ->
            {:ok, zipper}

          placement = placement(zipper, module) ->
            {target, where, name} = placement
            {:ok, Igniter.Code.Common.add_code(target, route_line(path, name, resource), where)}

          true ->
            {:warning,
             Igniter.Util.Warning.formatted_warning(
               "Could not find where to route this QuickView. Add it to the live_session running `AshQuick.LiveView.Mount`.",
               route_line(path, inspect(module), resource)
             )}
        end
      end)
    end

    # `:only` and `:except` name route shapes rather than resource actions, and
    # the one worth deciding here is `/create`: the list page reads the routes
    # back to decide whether to render a New button, so a resource nothing can
    # create is kept out of the flow by the router rather than by a policy.
    defp route_line(path, name, resource) do
      case Ash.Resource.Info.action(resource, :create) do
        %{type: :create} -> ~s|quick_view "#{path}", #{name}|
        _other -> ~s|quick_view "#{path}", #{name}, except: [:create]|
      end
    end

    # The path as well as the module, because a `scope` alias means the same
    # view is spelled two ways: a router already serving this path is already
    # serving this view, however it named it.
    defp routed?(zipper, path, module) do
      match?(
        {:ok, _zipper},
        Igniter.Code.Common.move_to(zipper, fn zipper ->
          quick_view_call?(zipper) and
            (Igniter.Code.Function.argument_equals?(zipper, 0, path) or
               Igniter.Code.Function.argument_equals?(zipper, 1, module))
        end)
      )
    end

    # Next to the QuickViews already routed, which is where a reader looks for
    # them. Failing that, inside the live_session running AshQuick's mount —
    # the one place a QuickView can serve from, since that stage is what
    # resolves the tab's impersonation and address.
    #
    # A candidate is only usable if the view's name can be written there: a
    # scope prefixes every module inside it, and Phoenix has no escape from
    # that short of `alias: false`.
    defp placement(zipper, module) do
      [after_last_quick_view(zipper), in_live_session(zipper)]
      |> Enum.reject(&is_nil/1)
      |> Enum.find_value(fn {target, where} ->
        case relative(module, scope_alias(target)) do
          nil -> nil
          name -> {target, where, name}
        end
      end)
    end

    defp after_last_quick_view(zipper) do
      case Igniter.Code.Common.move_to_last(zipper, &quick_view_call?/1) do
        {:ok, last} -> {last, placement: :after}
        :error -> nil
      end
    end

    defp in_live_session(zipper) do
      with {:ok, session} <- Igniter.Code.Common.move_to(zipper, &ash_quick_live_session?/1),
           {:ok, body} <- Igniter.Code.Common.move_to_do_block(session) do
        {body, placement: :after}
      else
        _other -> nil
      end
    end

    # `scope "/", MyAppWeb` prefixes every module written inside it, so a route
    # declared there with the full name resolves to `MyAppWeb.MyAppWeb....` — a
    # module that does not exist. The line is written the way the lines around
    # it are, and `nil` says this view cannot be written here at all.
    defp relative(module, []), do: inspect(module)

    defp relative(module, prefix) do
      case Enum.split(Module.split(module), length(prefix)) do
        {^prefix, [_ | _] = rest} -> Enum.join(rest, ".")
        _other -> nil
      end
    end

    defp scope_alias(zipper), do: scope_alias(zipper, [])

    # Stepping out of each scope before looking for the next: `move_upwards/2`
    # answers with the node it was handed when that node already matches.
    defp scope_alias(zipper, prefix) do
      case Igniter.Code.Common.move_upwards(zipper, &aliased_scope?/1) do
        {:ok, scope} -> enclosing_alias(scope, alias_parts(scope) ++ prefix)
        :error -> prefix
      end
    end

    defp enclosing_alias(scope, prefix) do
      case Igniter.Code.Common.move_upwards(scope, 1) do
        {:ok, parent} -> scope_alias(parent, prefix)
        :error -> prefix
      end
    end

    defp aliased_scope?(zipper) do
      Igniter.Code.Function.function_call?(zipper, :scope, 3) and alias_parts(zipper) != []
    end

    defp alias_parts(zipper) do
      with {:ok, argument} <- Igniter.Code.Function.move_to_nth_argument(zipper, 1),
           {:__aliases__, _meta, parts} <- Zipper.node(argument) do
        Enum.map(parts, &to_string/1)
      else
        _other -> []
      end
    end

    defp quick_view_call?(zipper) do
      Igniter.Code.Function.function_call?(zipper, :quick_view, [2, 3])
    end

    defp ash_quick_live_session?(zipper) do
      Igniter.Code.Function.function_call?(zipper, :live_session, [2, 3]) and
        zipper |> Zipper.node() |> Sourceror.to_string() =~ "AshQuick.LiveView.Mount"
    end

    # The route is served either way; what this decides is whether anyone may
    # navigate to it. A granted route missing here is a page that 403s with
    # nothing to say why, so the grant is written at the same time as the route.
    defp grant_route(igniter, path, roles) do
      access_control = Module.concat(Igniter.Libs.Phoenix.web_module(igniter), AccessControl)

      case grant_in(igniter, access_control, path, roles) do
        {:ok, igniter} ->
          igniter

        {:error, igniter} ->
          Igniter.add_notice(igniter, """
          #{inspect(access_control)} was not found, so "#{path}" is routed but \
          not granted to anyone. Add it to whichever module implements \
          `AshQuick.AccessControl`.
          """)
      end
    end

    defp grant_in(igniter, access_control, path, []) do
      Igniter.Project.Module.find_and_update_module(igniter, access_control, fn zipper ->
        add_to_routes(zipper, path)
      end)
    end

    # Per role, into the clause that answers for that role alone. A clause whose
    # list is built rather than written cannot be appended to without changing
    # what it means, so the role is reported instead.
    defp grant_in(igniter, access_control, path, roles) do
      with {:ok, {igniter, _source, zipper}} <-
             Igniter.Project.Module.find_module(igniter, access_control) do
        function = role_function(zipper)
        {grantable, missing} = Enum.split_with(roles, &role_list(zipper, function, &1))

        {:ok, igniter} =
          Igniter.Project.Module.find_and_update_module(igniter, access_control, fn zipper ->
            {:ok, Enum.reduce(grantable, zipper, &add_to_role(&2, function, &1, path))}
          end)

        {:ok, warn_ungranted(igniter, access_control, function, path, missing)}
      end
    end

    defp add_to_role(zipper, function, role, path) do
      {:ok, zipper} =
        Igniter.Code.Common.within(zipper, fn zipper ->
          {:ok, list} = role_list(zipper, function, role)
          append_route(list, path)
        end)

      zipper
    end

    # The function whose clauses are the roles' lists: the one `routes_for/1`
    # hands the role to, which is a one-argument function the module defines
    # by clauses on a literal atom; `routes_for_role/1` when nothing says
    # otherwise. Only its clauses are read, so a `label(:admin)` or a
    # `landing_for_role(:admin)` that happens to return a path is left alone.
    defp role_function(zipper) do
      tree = Zipper.node(zipper)
      clauses = role_clauses(tree)

      tree
      |> routes_for_bodies()
      |> Enum.flat_map(&local_calls/1)
      |> Enum.find(:routes_for_role, &(&1 in clauses))
    end

    defp routes_for_bodies(tree) do
      {_tree, bodies} =
        Macro.prewalk(tree, [], fn
          {def, _, [{:routes_for, _, [_scope]}, body]} = node, bodies
          when def in [:def, :defp] ->
            {node, [body | bodies]}

          node, bodies ->
            {node, bodies}
        end)

      Enum.reverse(bodies)
    end

    defp local_calls(body) do
      {_body, calls} =
        Macro.prewalk(body, [], fn
          {:|>, _, [_argument, {name, _, []}]} = node, calls when is_atom(name) ->
            {node, [name | calls]}

          {name, _, [_argument]} = node, calls when is_atom(name) ->
            {node, [name | calls]}

          node, calls ->
            {node, calls}
        end)

      Enum.reverse(calls)
    end

    defp role_clauses(tree) do
      {_tree, names} =
        Macro.prewalk(tree, MapSet.new(), fn
          {def, _, [{name, _, [argument]}, _body]} = node, names
          when def in [:def, :defp] and is_atom(name) ->
            if is_atom(literal(argument)),
              do: {node, MapSet.put(names, name)},
              else: {node, names}

          node, names ->
            {node, names}
        end)

      names
    end

    defp role_list(zipper, function, role) do
      with {:ok, clause} <-
             Igniter.Code.Common.move_to(zipper, &role_clause?(&1, function, role)),
           {:ok, body} <- Igniter.Code.Common.move_to_do_block(clause),
           body = Igniter.Code.Common.maybe_move_to_single_child_block(body),
           true <- route_list?(Zipper.node(body)) do
        {:ok, body}
      else
        _other -> nil
      end
    end

    defp role_clause?(zipper, function, role) do
      case Zipper.node(zipper) do
        {def, _meta, [{^function, _, [argument]}, _body]} when def in [:def, :defp] ->
          match?(atom when is_atom(atom), literal(argument)) and
            to_string(literal(argument)) == role

        _other ->
          false
      end
    end

    defp route_list?({:sigil_w, _meta, [{:<<>>, _, [words]}, []]}) when is_binary(words),
      do: words |> String.split() |> Enum.all?(&String.starts_with?(&1, "/"))

    defp route_list?({:__block__, _meta, [elements]}) when is_list(elements),
      do: route_list?(elements)

    defp route_list?(elements) when is_list(elements),
      do: Enum.all?(elements, &(is_binary(literal(&1)) and literal(&1) =~ ~r|^/|))

    defp route_list?(_node), do: false

    defp append_route(zipper, path) do
      case Zipper.node(zipper) do
        {:sigil_w, meta, [{:<<>>, words_meta, [words]}, []]} ->
          if path in String.split(words) do
            {:ok, zipper}
          else
            node = {:sigil_w, meta, [{:<<>>, words_meta, [append_word(words, path)]}, []]}
            {:ok, Zipper.replace(zipper, node)}
          end

        _list ->
          Igniter.Code.List.append_new_to_list(zipper, path)
      end
    end

    # A word list written one route to a line keeps that shape; any other gets
    # the route after its last word.
    defp append_word(words, path) do
      body = String.trim_trailing(words)
      trailing = String.replace_prefix(words, body, "")
      lines = body |> String.split("\n") |> Enum.reject(&(String.trim(&1) == ""))

      cond do
        lines == [] ->
          path

        length(lines) > 1 and Enum.all?(lines, &match?([_], String.split(&1))) ->
          [indent] = Regex.run(~r/^\s*/, List.last(lines))
          body <> "\n" <> indent <> path <> trailing

        true ->
          body <> " " <> path <> trailing
      end
    end

    defp warn_ungranted(igniter, _access_control, _function, _path, []), do: igniter

    defp warn_ungranted(igniter, access_control, function, path, missing) do
      Igniter.add_warning(igniter, """
      #{inspect(access_control)} has no `#{function}/1` clause for \
      #{Enum.map_join(missing, ", ", &(":" <> &1))} whose routes are a literal list \
      or `~w(...)`, so "#{path}" is not granted \
      to #{if length(missing) == 1, do: "it", else: "them"}. Grant it there by hand. \
      #{strict_note()}
      """)
    end

    defp strict_note do
      "`mix ash_quick.check --strict` fails on a routed QuickView no role holds, " <>
        "as an `:unreachable_entry`, when the nav names this access control and it " <>
        "exports `all_routes/0`."
    end

    defp add_to_routes(zipper, path) do
      with {:ok, zipper} <- Igniter.Code.Common.move_to(zipper, &routes_attribute?/1),
           {:ok, zipper} <- Igniter.Code.Function.move_to_nth_argument(Zipper.down(zipper), 0) do
        Igniter.Code.List.append_new_to_list(zipper, path)
      else
        _other ->
          {:warning,
           Igniter.Util.Warning.formatted_warning(
             "Could not find a `@routes` list to grant this route in. Grant it wherever `AshQuick.AccessControl` is implemented, or name the roles with `--grant-to` when it lists routes per role. " <>
               strict_note(),
             ~s|"#{path}"|
           )}
      end
    end

    defp routes_attribute?(zipper) do
      match?({:@, _meta, [{:routes, _, _}]}, Zipper.node(zipper))
    end

    defp module(igniter, resource, options) do
      case options[:module] do
        nil ->
          web = Igniter.Libs.Phoenix.web_module(igniter)
          Module.concat([web, "#{List.last(Module.split(resource))}Live", Quick])

        name ->
          Igniter.Project.Module.parse(name)
      end
    end

    # The resource's own plural name, so the path, the sidebar label and the
    # resource agree without any of them being restated.
    defp path(resource, options) do
      case options[:path] do
        nil -> "/#{Ash.Resource.Info.plural_name(resource) || inflected(resource)}"
        path -> path
      end
    end

    defp inflected(resource) do
      resource
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
      |> Igniter.Inflex.pluralize()
    end
  end
else
  defmodule Mix.Tasks.AshQuick.Gen.QuickView do
    @shortdoc "Generates a QuickView over a resource, routes it, and grants the route"

    @moduledoc @shortdoc

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_quick.gen.quick_view' requires igniter to be run.

      Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter
      """)

      exit({:shutdown, 1})
    end
  end
end
