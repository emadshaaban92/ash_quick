defmodule AshQuick.LiveView.QuickView.Resolve do
  @moduledoc false
  # What a URL resolves to: the params a page renders from, and the action
  # it renders them through, or none where the URL names one it cannot serve.
  alias Ash.Resource.Actions
  alias AshQuick.LiveView.URLParams
  alias AshQuick.LiveView.QuickView.Options

  def resolve(url_params, %Options{} = options, live_action) do
    params =
      url_params
      |> URLParams.from_url_params()
      |> params_for_shape(live_action)

    action_name = action_from_params(params, options, live_action)

    action =
      if reachable?(options, action_name),
        do: resolved_action(options.resource, action_name, params)

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

  # `/create` is the only shape `quick_view/3` declares with a `live_action`,
  # and the only one whose path holds no `:id` — so an `?id=` there names
  # nothing. Dropped rather than refused, and dropping it is also what carries
  # it out of the canonicalized URL.
  defp params_for_shape(%URLParams{} = params, nil), do: params

  defp params_for_shape(%URLParams{} = params, _live_action),
    do: %URLParams{params | id: nil}

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

  def action_from_params(%URLParams{action: action}, _config, _live_action)
      when not is_nil(action) do
    action
  end

  def action_from_params(%URLParams{id: nil}, _config, live_action)
      when not is_nil(live_action) do
    live_action
  end

  def action_from_params(%URLParams{id: nil}, %Options{} = options, nil) do
    options.list_default_action
  end

  def action_from_params(%URLParams{action: nil, id: id}, %Options{} = options, nil)
      when not is_nil(id) do
    options.details_default_action
  end
end
