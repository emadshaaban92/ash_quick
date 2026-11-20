defmodule AshQuick.LiveView.QuickView.Resolve do
  @moduledoc false
  # What a URL resolves to: the params a page renders from, and the action
  # it renders them through, or none where the URL names one it cannot serve.
  alias Ash.Resource.Actions
  alias AshQuick.LiveView.URLParams
  alias AshQuick.LiveView.QuickView.Options

  def resolve(url_params, %Options{} = options, %{shape: shape, served: served}) do
    params =
      url_params
      |> URLParams.from_url_params()
      |> params_for_shape(shape)

    action_name = action_from_params(params, options, shape)

    action =
      if reachable?(options, action_name),
        do: resolved_action(options.resource, action_name, params)

    action = if action && served?(action, params, served), do: action

    params =
      params
      |> paginate(action, options)
      |> URLParams.allow_sort(options.list_sortable)

    {params, action}
  end

  def resolve_parent(%Options{} = options, action_name, params) do
    if reachable?(options, action_name),
      do: resolved_action(options.resource, action_name, params)
  end

  # Every page is sized by a list: a list page by its own action, and a record
  # or create page by the list it links back to, which is the default one. So
  # a record page holding `?limit=20` under a list whose default is 2 says so
  # in every link back, rather than measuring it against a default no list has.
  defp paginate(%URLParams{id: nil} = params, %Actions.Read{get?: false} = action, _options),
    do: size_by(params, action)

  defp paginate(params, _action, %Options{} = options),
    do: size_by(params, Ash.Resource.Info.action(options.resource, options.list_default_action))

  # The page behind a modal is sized only when it is a list. A record page
  # behind an update keeps the size `paginate/3` gave it.
  def apply_pagination(%URLParams{id: nil} = params, action), do: size_by(params, action)
  def apply_pagination(params, _action), do: params

  # A list reads its action's `default_limit` unless the URL says otherwise, and
  # at most its `max_page_size`, so that is the most its page may say it reads.
  # See `URLParams.apply_pagination/2`.
  defp size_by(params, %Actions.Read{pagination: %{} = pagination}),
    do: URLParams.apply_pagination(params, pagination)

  defp size_by(params, _action), do: params

  # A URL names actions on the visitor's behalf, so it reaches only public
  # ones. See `AshQuick.LiveView.Utils.record_actions/1` for what a private
  # action is, and why the policy Ash recommends for one cannot be relied on to
  # refuse a visitor. The page's own defaults are the exception, because the
  # host named them in code: a lookup action kept private so that no API serves
  # it is still what this page lists through.
  defp reachable?(%Options{} = options, action_name) do
    action_name in [options.list_default_action, options.details_default_action] or
      AshQuick.LiveView.Utils.public_action?(options.resource, action_name)
  end

  # The params a page reads arrive with the path's and the query's merged, the
  # path's winning, so an `id` or an `action` the route's path does not hold
  # came from the query. Only the route says which: see the `:shape` that
  # `quick_view/3` puts on it.
  #
  # The id is the path's alone. Nothing writes `?id=`, and read from the query
  # it reached a record page, or a write action over one, under a base path
  # served only as a list. `?action=` is read only where no id is, which is
  # the only place it is written: a second list or a second create has no path
  # segment to be named in. Under an id the path names the action, so the
  # query's is a second spelling of a route that may not be served.
  #
  # Dropped rather than refused, like any other query value nothing may say,
  # and dropping them is also what carries them out of the canonicalized URL.
  defp params_for_shape(%URLParams{} = params, shape) when shape in [:index, :create],
    do: %URLParams{params | id: nil}

  defp params_for_shape(%URLParams{} = params, :show), do: %URLParams{params | action: nil}

  defp params_for_shape(%URLParams{} = params, :action), do: params

  # Whether a route is served for the page `action` renders. An `/:id` or
  # `/:id/:action` page is only reached on its own route, but `?action=` on an
  # id-less one names a list or a create, whichever route it arrived on, and
  # each needs its own: a base path routed `except: [:create]` lists, and opens
  # no create form for `?action=create`.
  #
  # A read under an id is not held to `:show`: `/:id/:action` serves every
  # action the resource has, reads among them, so on a base path routed
  # `only: [:index, :action]` `/<id>/<read>` is a route that is served.
  defp served?(%Actions.Read{}, %URLParams{id: nil}, served), do: :index in served
  defp served?(%Actions.Create{}, _params, served), do: :create in served
  defp served?(_action, _params, _served), do: true

  # The combinations `QuickView.Page.do_handle_params/4` serves, mirrored: a URL naming
  # any other pairing of shape and action resolves to no action rather than
  # reaching a clause that is not there. The list's read is held to
  # `Lookup.Contract` on top — what a list needs of a read, and what `Options`
  # already holds a declared `default_action` to while the page compiles.
  defp resolved_action(resource, action_name, %URLParams{id: nil}) do
    case Ash.Resource.Info.action(resource, action_name) do
      %Actions.Read{get?: false} = action -> if listable?(resource, action), do: action
      %Actions.Create{} = action -> action
      _ -> nil
    end
  end

  defp resolved_action(resource, action_name, %URLParams{}) do
    case Ash.Resource.Info.action(resource, action_name) do
      %Actions.Read{} = action -> action
      %Actions.Update{} = action -> action
      %Actions.Destroy{} = action -> action
      _ -> nil
    end
  end

  defp listable?(resource, %Actions.Read{} = action) do
    AshQuick.Lookup.Contract.check(
      resource,
      action.name,
      AshQuick.Info.lookup_search_argument(resource)
    ) == :ok
  end

  def action_from_params(%URLParams{action: action}, _config, _shape)
      when not is_nil(action) do
    action
  end

  # `/create` names its action by its shape; every other shape that names
  # none reads the page's default.
  def action_from_params(%URLParams{id: nil}, _config, :create), do: :create

  def action_from_params(%URLParams{id: nil}, %Options{} = options, _shape) do
    options.list_default_action
  end

  def action_from_params(%URLParams{action: nil, id: id}, %Options{} = options, _shape)
      when not is_nil(id) do
    options.details_default_action
  end
end
