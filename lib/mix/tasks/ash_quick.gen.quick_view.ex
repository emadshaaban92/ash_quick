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
        twenty columns a list is read for.
      * One `quick_view/3` line in the router, placed with the QuickViews that
        are already there or in the live_session running
        `AshQuick.LiveView.Mount`. A resource with no `:create` action is routed
        `except: [:create]`, which is what keeps something the system creates
        out of the "New" flow.
      * The path, in the application's `AshQuick.AccessControl`. Without it the
        route exists and every navigation to it is refused.

    The sidebar needs nothing further: a QuickView is discovered from its route.
    A tile in the apps grid is a `group` in the nav, which is a decision about
    where the page belongs rather than one this task can make.

    ## Options

      * `--path` - The base path to serve it at. Defaults to the resource's
        `plural_name`.
      * `--module` - The QuickView module. Defaults to
        `MyAppWeb.<Resource>Live.Quick`.
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
        schema: [path: :string, module: :string]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      resource = Igniter.Project.Module.parse(igniter.args.positional.resource)

      case validate(resource) do
        :ok -> generate(igniter, resource)
        {:error, message} -> Igniter.add_issue(igniter, message)
      end
    end

    # The field list is read off the compiled resource, so the resource has to
    # be one: a name that resolves to nothing, or to a module that never took
    # the extension, is reported as itself rather than as a page that renders
    # a label of `nil`.
    defp validate(resource) do
      cond do
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
      |> generate_module(module, resource)
      |> add_route(router, path, module, resource)
      |> grant_route(path)
    end

    defp generate_module(igniter, module, resource) do
      list = fields(resource)
      details = list ++ (AshQuick.Info.timestamp_fields(resource) -- list)

      case Igniter.Project.Module.module_exists(igniter, module) do
        {true, igniter} ->
          Igniter.add_warning(igniter, "#{inspect(module)} already exists; left as it is.")

        {false, igniter} ->
          Igniter.copy_template(
            igniter,
            :ash_quick
            |> Application.app_dir("priv/templates/ash_quick.gen.quick_view")
            |> Path.join("quick.ex.eex"),
            Igniter.Project.Module.proper_location(igniter, module),
            [
              module: module,
              resource: resource,
              list_fields: inspect(list),
              details_fields: inspect(details)
            ],
            on_exists: :skip
          )
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
    defp grant_route(igniter, path) do
      access_control = Module.concat(Igniter.Libs.Phoenix.web_module(igniter), AccessControl)

      case Igniter.Project.Module.find_and_update_module(igniter, access_control, fn zipper ->
             add_to_routes(zipper, path)
           end) do
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

    defp add_to_routes(zipper, path) do
      with {:ok, zipper} <- Igniter.Code.Common.move_to(zipper, &routes_attribute?/1),
           {:ok, zipper} <- Igniter.Code.Function.move_to_nth_argument(Zipper.down(zipper), 0) do
        Igniter.Code.List.append_new_to_list(zipper, path)
      else
        _other ->
          {:warning,
           Igniter.Util.Warning.formatted_warning(
             "Could not find a `@routes` list to grant this route in. Grant it wherever `AshQuick.AccessControl` is implemented.",
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
