defmodule AshQuick.LiveView.Router do
  @moduledoc """
  Declares the routes a QuickView serves.

  A QuickView answers up to four paths that differ only in what the URL
  carries, so the router states the base path once:

      import AshQuick.LiveView.Router

      quick_view "/products", MyAppWeb.ProductLive.Quick

  expands to

      live "/products",             MyAppWeb.ProductLive.Quick, nil
      live "/products/create",      MyAppWeb.ProductLive.Quick, :create
      live "/products/:id",         MyAppWeb.ProductLive.Quick, nil
      live "/products/:id/:action", MyAppWeb.ProductLive.Quick, nil

  ## Choosing which routes to serve

  `:only` and `:except` select from the four shapes above — `:index`,
  `:create`, `:show` and `:action`. They do not name resource actions: a
  single `/:id/:action` route serves every action the resource has, so the
  router never has to be revisited when one is added.

      quick_view "/audit_logs", MyAppWeb.AuditLogLive.Quick, only: [:index, :show]
      quick_view "/items", MyAppWeb.ItemLive.Quick, except: [:create]

  Omitting `:create` is how a resource that exists only through the system —
  an audit log, a materialised item — is kept out of the "New" flow: the list
  page reads the routes back through `served_shapes/2` and renders no New
  button for a base path with no `/create` route, whatever the create policy
  says. Passing both `:only` and `:except` is an error.

  ## Why the macro is the only supported way to route a QuickView

  Each generated route carries its base path as route metadata, and that is
  where the QuickView reads it from at request time. The path is therefore
  stated once, in the router, and cannot drift from the module. A QuickView
  reached through a hand-written `live/3` has no base path to find and says
  so rather than rendering a page whose every link is broken.

  What it carries is the path the route is *served* at, so a `quick_view`
  inside `scope "/admin"` answers `/admin/products` and builds its links from
  `/admin/products` too.
  """

  # Order here is match order, and it is load-bearing: `/create` must be
  # declared before `/:id`, or `/products/create` matches the show route with
  # an id of "create".
  @shapes [
    index: {"", nil},
    create: {"/create", :create},
    show: {"/:id", nil},
    action: {"/:id/:action", nil}
  ]

  @names Keyword.keys(@shapes)

  @doc """
  Routes `path` to `live_view`, a module using `AshQuick.LiveView.QuickView`.

  Accepts `:only` or `:except`, taking a subset of
  `#{inspect(Keyword.keys(@shapes))}`. See the module documentation.
  """
  defmacro quick_view(path, live_view, opts \\ [])

  defmacro quick_view(path, live_view, opts) when is_binary(path) and is_list(opts) do
    routes =
      for {route, live_action} <- __routes__(path, opts) do
        quote do
          Phoenix.LiveView.Router.live(
            unquote(route),
            unquote(live_view),
            unquote(live_action),
            metadata: %{
              ash_quick: %{
                # The path a `scope` prefix puts the route at, not the literal
                # written here: the page builds its links from this, and a base
                # path missing the prefix points every one of them outside the
                # scope the route lives in.
                base_path: Phoenix.Router.scoped_path(__MODULE__, unquote(path))
              }
            }
          )
        end
      end

    quote do
      require Phoenix.LiveView.Router
      (unquote_splicing(routes))
    end
  end

  defmacro quick_view(path, _live_view, opts) do
    raise ArgumentError, """
    quick_view/3 expects a literal path and a literal option list, so that the
    routes it declares can be built at compile time.

    Got path: #{Macro.to_string(path)}
        opts: #{Macro.to_string(opts)}
    """
  end

  @doc """
  Which of the four shapes `base_path` is actually served at on `router`.

  The read side of `:only` and `:except`. A QuickView renders controls that lead
  to routes it may not have been given — the New button is the one that matters,
  because it is gated on the create policy and nothing else — so the page asks
  what it is allowed to offer rather than assuming all four.

  Matched on the literal route paths rather than through
  `Phoenix.Router.route_info/4`, which would resolve `<base>/create` against the
  `/:id` route and report a create route that is not there.
  """
  @spec served_shapes(module(), String.t()) :: MapSet.t(atom())
  def served_shapes(router, base_path) do
    paths = MapSet.new(Phoenix.Router.routes(router), & &1.path)

    for {name, {suffix, _live_action}} <- @shapes,
        MapSet.member?(paths, base_path <> suffix),
        into: MapSet.new(),
        do: name
  end

  @doc """
  The path the `shape` route is served at under `base_path`.

  The other read side of `@shapes`, next to `served_shapes/2`: a shape's suffix
  is stated once, where the routes are declared, so nothing that has to name one
  writes it out a second time.

  Answers for any of `#{inspect(@names)}` whether or not that shape is routed —
  it says where the route would be, not that it is there. `served_shapes/2` is
  what answers the second question.
  """
  @spec shape_path(String.t(), atom()) :: String.t()
  def shape_path(base_path, shape) when is_binary(base_path) and shape in @names do
    {suffix, _live_action} = Keyword.fetch!(@shapes, shape)
    base_path <> suffix
  end

  @doc false
  def __routes__(path, opts) do
    selected = selected_shapes(opts)

    for {name, {suffix, live_action}} <- @shapes,
        name in selected,
        do: {path <> suffix, live_action}
  end

  defp selected_shapes(opts) do
    case {Keyword.get(opts, :only), Keyword.get(opts, :except)} do
      {nil, nil} ->
        @names

      {only, nil} ->
        validate!(only, :only)

      {nil, except} ->
        validate!(except, :except)
        reject_empty!(@names -- except, except)

      {_only, _except} ->
        raise ArgumentError,
              "quick_view/3 accepts :only or :except, not both"
    end
  end

  defp validate!(shapes, key) when is_list(shapes) and shapes != [] do
    case Enum.reject(shapes, &(&1 in @names)) do
      [] -> shapes
      unknown -> raise ArgumentError, invalid_message(key, unknown)
    end
  end

  defp validate!(shapes, key), do: raise(ArgumentError, invalid_message(key, shapes))

  defp reject_empty!([], except) do
    raise ArgumentError, """
    quick_view/3 :except of #{inspect(except)} leaves no routes at all. A
    QuickView that serves nothing should not be routed.
    """
  end

  defp reject_empty!(shapes, _except), do: shapes

  defp invalid_message(key, got) do
    """
    quick_view/3 :#{key} expects a non-empty list drawn from #{inspect(@names)}.

    Got: #{inspect(got)}

    These name route shapes, not resource actions — `/:id/:action` already
    serves every action the resource has.
    """
  end
end
