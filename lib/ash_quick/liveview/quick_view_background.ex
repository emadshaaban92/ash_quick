defmodule AshQuick.LiveView.QuickView.Background do
  @moduledoc false
  # The page a create or an update opens over, or returns to: a snapshot
  # of where the visitor was, or the page the action belongs to.
  import Phoenix.Component, only: [assign: 2, assign: 3]
  alias Ash.Resource.Actions
  alias AshQuick.LiveView.URLParams
  alias AshQuick.LiveView.QuickView.Options
  alias AshQuick.LiveView.QuickView.Page
  alias AshQuick.LiveView.QuickView.Resolve
  alias AshQuick.LiveView.Liveness

  # Public only because the generated `handle_params/3` calls it.
  #
  # A create or an update opens in a modal over the page the visitor was on —
  # a snapshot of it, since the socket now holds the form. It is the page they
  # come back to, so where they came from needs no tracking: an action opened
  # from the list closes onto the list, at the page and filters it had.
  #
  # One action opened from another keeps the page the first opened over. A URL
  # reached with nothing before it — a link, a refresh — opens over the page
  # the action belongs to: the record's details for an update, the list for a
  # create.
  #
  # Either way the background says where that page is (`:path`), and what it
  # showed (`:params`, `:record`), which is how a destroy tells whether it
  # destroyed the record its page was about. A modal's also holds the page's
  # `:assigns`, which it is drawn over; an action the resource declared
  # `full_page` is drawn on its own and holds none, so it returns to the same
  # page without rendering it.
  def put_background(socket, previous, %URI{} = uri, %Options{} = options, after_handle_params) do
    action = socket.assigns.ash_action

    background =
      cond do
        match?(%Actions.Read{}, action) ->
          nil

        AshQuick.Info.full_page?(options.resource, action.name) ->
          return_to(socket, previous, options)

        true ->
          modal_background(socket, previous, action, options, after_handle_params)
      end

    socket
    |> assign(:ash_quick_background, background)
    |> assign(:ash_quick_request_path, request_path(uri))
  end

  # Where this page is, query and all, for an action opened over it to return to.
  defp request_path(%URI{path: path, query: nil}), do: path
  defp request_path(%URI{path: path, query: query}), do: "#{path}?#{query}"

  defp modal_background(socket, previous, action, options, after_handle_params) do
    case previous do
      %{ash_quick_background: %{assigns: %{}} = background} ->
        background

      %{ash_action: %Actions.Read{}, ash_quick_request_path: path} ->
        page(path, snapshot(previous))

      _previous ->
        parent_background(socket, action, options, after_handle_params)
    end
  end

  # A full page draws nothing underneath, so the page it returns to is only
  # named. With nothing before it, that is the page the action belongs to, at
  # the URL's own search and filters: the list it lands on reads it then.
  defp return_to(socket, previous, %Options{} = options) do
    case previous do
      %{ash_quick_background: %{} = background} ->
        Map.delete(background, :assigns)

      %{ash_action: %Actions.Read{}, ash_quick_request_path: path} ->
        path |> page(previous) |> Map.delete(:assigns)

      _previous ->
        parent_return(socket, options)
    end
  end

  defp page(path, assigns),
    do: %{path: path, params: assigns.params, record: assigns[:record], assigns: assigns}

  defp parent_return(socket, %Options{} = options) do
    params = parent_params(socket.assigns.params, socket.assigns.ash_action)

    if params
       |> Resolve.action_from_params(options, nil)
       |> then(&Resolve.resolve_parent(options, &1, params)) do
      %{
        path: URLParams.full_path(socket.assigns.base_path, params),
        params: params,
        record: nil
      }
    end
  end

  defp parent_background(socket, action, %Options{} = options, after_handle_params) do
    params = parent_params(socket.assigns.params, action)

    parent_action =
      params
      |> Resolve.action_from_params(options, nil)
      |> then(&Resolve.resolve_parent(options, &1, params))

    if parent_action do
      params = Resolve.apply_pagination(params, parent_action)

      parent =
        socket
        |> assign(params: params, ash_action: parent_action)
        |> Page.do_handle_params(params, parent_action, options)
        |> after_handle_params.()

      # Only rendered, never live: what loading it subscribed to is let go.
      Liveness.unsubscribe_all(parent, options)

      page(
        URLParams.full_path(socket.assigns.base_path, parent.assigns.params),
        snapshot(parent.assigns)
      )
    end
  end

  defp parent_params(%URLParams{} = params, %Actions.Create{}),
    do: %URLParams{params | action: nil, id: nil}

  defp parent_params(%URLParams{} = params, _record_action), do: %URLParams{params | action: nil}

  # Rendered whole whenever it renders at all, which is only when it is taken.
  defp snapshot(assigns) do
    assigns
    |> Map.drop([:flash, :ash_quick_background])
    |> Map.put(:__changed__, nil)
  end
end
