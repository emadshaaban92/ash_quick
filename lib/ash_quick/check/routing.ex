defmodule AshQuick.Check.Routing do
  @moduledoc false
  # The router held to what a QuickView reads off it at request time.
  #
  # `quick_view/3` decides its routes at compile time and refuses what it cannot
  # build, so everything it *declares* is right by construction. What it cannot
  # see is the router around it: a QuickView someone routed with a plain
  # `live/3` instead, a route labelled as a QuickView's that leads to something
  # else, and a route set narrowed past an action that still renders a button.
  #
  # None of these raises. Each is a page whose links are wrong, or a button that
  # patches to a path the router does not serve, discovered by whoever clicked
  # it.

  alias AshQuick.Check.Finding

  def run(nil), do: {[], [{:routing, "no router was given, so no route was read"}]}

  def run(router) do
    all = Phoenix.Router.routes(router)
    served = MapSet.new(all, & &1.path)
    live_routes = Enum.filter(all, &(&1.plug == Phoenix.LiveView.Plug))

    findings =
      hand_routed(router, live_routes) ++
        mislabelled(router, live_routes) ++
        stray_base_paths(live_routes) ++
        route_gaps(live_routes, served)

    {findings, []}
  end

  defp hand_routed(router, routes) do
    for route <- routes,
        quick_view?(route),
        not match?(%{ash_quick: %{base_path: _}}, route.metadata) do
      %Finding{
        check: :hand_routed_quick_view,
        subject: route.path,
        message: """
        #{route.path} leads to #{inspect(view(route))}, a QuickView, but was \
        declared with a plain `live/3`.

        A QuickView reads the path it builds every link from off its route's \
        metadata, and only `quick_view/3` writes it. So this page does not \
        render with broken links — it raises the first time it is asked for one.

            import AshQuick.LiveView.Router

            quick_view "#{base_guess(route.path)}", #{inspect(view(route))}

        in #{inspect(router)}.
        """
      }
    end
  end

  defp mislabelled(router, routes) do
    for route <- routes, Map.has_key?(route.metadata, :ash_quick), not quick_view?(route) do
      %Finding{
        check: :mislabelled_route,
        subject: route.path,
        message: """
        #{route.path} carries `ash_quick` route metadata, but \
        #{inspect(view(route))} is not a QuickView.

        The metadata is what `AshQuick.Nav.Info` discovers a page by, so this \
        route puts an entry in the sidebar and a tile in the apps grid for a \
        view that knows nothing about either — and tries to read a resource off \
        it to label them with. Drop the metadata in #{inspect(router)}, or \
        point the route at the QuickView it was meant for.
        """
      }
    end
  end

  # A `quick_view` inside a `scope` is served under the prefix and carries the
  # prefixed path, so the two agreeing is what says the metadata survived the
  # scope rather than recording the literal path written in the macro.
  defp stray_base_paths(routes) do
    for route <- routes,
        quick_view?(route),
        %{ash_quick: %{base_path: base}} <- [route.metadata],
        not under?(route.path, base) do
      %Finding{
        check: :stray_base_path,
        subject: route.path,
        message: """
        #{route.path} is served outside the base path it carries, #{base}.

        #{inspect(view(route))} builds every link it renders from #{base}, so \
        each one leads out of the part of the router this route actually lives \
        in.
        """
      }
    end
  end

  # `:only` and `:except` narrow which of the four routes a QuickView answers,
  # and two controls it renders can outlive the route they lead to.
  #
  # The New button is not one of them any more: `ListView` gates it on the
  # `:create` shape being served, so omitting the route really does keep a
  # resource out of the New flow, the way `quick_view/3` documents. Hiding a
  # control is the right answer when the router said unambiguously that the page
  # does not have it, and `:only`/`:except` name that shape directly.
  #
  # Neither of these can be settled that way:
  #
  #   * the row's "View details" link is only one of the things that lead to
  #     `<base>/<id>` — a create redirects there too — so hiding the link would
  #     leave the gap and remove the evidence of it;
  #   * `/:id/:action` serves *every* action at once, so leaving it out says
  #     nothing about any particular one. There is no way to tell a deliberate
  #     omission from a forgotten route, and silently dropping the button would
  #     hide an action somebody needs.
  #
  # So these are reported rather than guessed at.
  #
  # A base path with no resource behind it is skipped: that is a route carrying
  # metadata it has no business carrying, already reported as
  # `:mislabelled_route`, and it renders no rows and no buttons either.
  defp route_gaps(routes, served) do
    routes
    |> quick_views()
    |> Enum.flat_map(fn
      {_base, nil} ->
        []

      {base, resource} ->
        missing_show(base, resource, served) ++ missing_actions(base, resource, served)
    end)
  end

  # Guarded on the list being served: with no list there are no rows, and
  # nothing renders the link.
  defp missing_show(base, resource, served) do
    if MapSet.member?(served, base) and not MapSet.member?(served, base <> "/:id") do
      [
        %Finding{
          check: :unroutable_show,
          subject: base <> "/:id",
          message: """
          #{base} lists #{inspect(resource)} and serves no `/:id` route.

          Every row renders a "View details" link to #{base}/<id>, and a \
          successful create redirects there. Both are 404s.

              quick_view "#{base}", TheLive.Quick, only: [:index, :show]
          """
        }
      ]
    else
      []
    end
  end

  defp missing_actions(base, resource, served) do
    if MapSet.member?(served, base <> "/:id/:action") do
      []
    else
      Enum.map(input_taking_actions(resource), &unroutable_action(base, resource, &1))
    end
  end

  defp unroutable_action(base, resource, action) do
    %Finding{
      check: :unroutable_action,
      subject: "#{base}/:id/#{action.name}",
      message: """
      #{inspect(resource)}'s #{inspect(action.name)} takes inputs, and \
      #{base} serves no `/:id/:action` route.

      An update or destroy taking inputs needs a form, so its button patches to \
      #{base}/:id/#{action.name} rather than running the action inline. The \
      button renders as soon as the action's policies allow it — a policy that \
      denies it today is all that is standing between this and a 404.

      Either widen the route set:

          quick_view "#{base}", TheLive.Quick

      or, if this action is genuinely not meant to be taken from the UI, forbid \
      it rather than leaving the router to hide it.
      """
    }
  end

  defp input_taking_actions(nil), do: []

  defp input_taking_actions(resource) do
    resource
    |> Ash.Resource.Info.actions()
    |> Enum.filter(&(&1.type in [:update, :destroy]))
    |> Enum.reject(&Enum.empty?(Ash.Resource.Info.action_inputs(resource, &1.name)))
  end

  @doc false
  # Every QuickView the router serves, as `{base_path, resource}` — one entry
  # per page rather than one per route.
  def quick_views(routes) do
    routes
    |> Enum.flat_map(fn route ->
      case route.metadata do
        %{ash_quick: %{base_path: base}} -> [{base, resource(route)}]
        _metadata -> []
      end
    end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp under?(path, base), do: path == base or String.starts_with?(path, base <> "/")

  # The base path a hand-written route was probably meant to declare: everything
  # up to the first dynamic segment, so `/scan/:id` suggests `/scan`.
  defp base_guess(path) do
    path
    |> String.split("/")
    |> Enum.take_while(&(not String.starts_with?(&1, ":")))
    |> Enum.join("/")
    |> case do
      "" -> path
      guess -> guess
    end
  end

  defp resource(route) do
    view = view(route)

    if Code.ensure_loaded?(view) and function_exported?(view, :__ash_quick_options__, 0) do
      view.__ash_quick_options__().resource
    end
  end

  # `Code.ensure_loaded?` first: `function_exported?/3` answers false for a
  # module that is merely not loaded yet, which would read as "this QuickView is
  # not one" and report every page in the application.
  defp quick_view?(route) do
    view = view(route)
    Code.ensure_loaded?(view) and function_exported?(view, :__ash_quick_options__, 0)
  end

  defp view(route), do: elem(route.metadata.phoenix_live_view, 0)
end
