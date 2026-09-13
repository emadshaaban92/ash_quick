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
  an audit log, a materialised item — is kept out of the "New" flow. Passing
  both `:only` and `:except` is an error.

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
