defmodule AshQuick.LiveView.QuickView.Address do
  @moduledoc false
  # The URL a QuickView is served at: the base path its route carries, and
  # the query string corrected to what the page rendered.
  alias AshQuick.LiveView.URLParams

  def base_path!(socket, %URI{} = uri), do: route!(socket, uri).base_path

  # The route being served: its base path, which of the four shapes it is, and
  # which shapes its base path is served at. See `QuickView.route!/2`.
  def route!(socket, %URI{} = uri) do
    case Phoenix.Router.route_info(socket.router, "GET", uri.path, uri.host) do
      %{ash_quick: %{base_path: base_path, shape: shape}} ->
        %{
          base_path: base_path,
          shape: shape,
          served: AshQuick.LiveView.Router.served_shapes(socket.router, base_path)
        }

      _ ->
        raise """
        #{inspect(socket.view)} was reached at #{uri.path}, through a route that \
        carries no AshQuick metadata.

        QuickView routes must be declared with `quick_view/3`, which is what \
        pins the base path onto the route:

            import AshQuick.LiveView.Router

            quick_view "#{uri.path}", #{inspect(socket.view)}
        """
    end
  end

  # Public only because the generated `handle_params/3` calls it.
  #
  # The page renders what the query string *parsed* to, so the address
  # bar is made to say the same thing rather than keep the promise the
  # link made: a limit past the ceiling, a page before the first, a
  # filter that will not decode. Corrected at the first render or not
  # at all — that is the moment the visitor can still tie the link they
  # followed to the list they got, and by the time a control rebuilds
  # the path the evidence of what was dropped has gone with it.
  #
  # Read back off the socket rather than from `params`, because the
  # parse is not the last thing that can drop a value: a custom filter
  # the data layer will not take decodes perfectly well and is refused
  # at the read, where `ListUtils.do_handle_params/4` drops it.
  #
  # `:params` in assigns is the page's record of what it actually
  # rendered, and every control already rebuilds its path from there
  # rather than from the query string — `handle_list_events/4` does it
  # for search, paging and filters. Correcting the query from the same
  # place is that rule applied to the address bar, not a new contract.
  #
  # Only what `URLParams` models survives, so an unmodeled `?foo=bar`
  # is dropped here. That is not a new loss: every control has always
  # rebuilt the path from the parsed struct alone, so the first click
  # dropped it anyway. This only makes the library honest about it at
  # the render the visitor is looking at.
  #
  # The query is corrected; the path never is. `full_path/2` rebuilds
  # both, but a path derived from the parsed params is a navigation
  # rather than a tidy-up when it disagrees with the one being served —
  # see `correctable_query?/2`, which is what refuses those.
  #
  # Which is why `/create` needs its base named rather than rebuilt.
  # It is the only one of the four shapes carrying no path param — its
  # action comes from the router's `live_action` — so the parsed params
  # rebuild it as the *index* path, the two never agree, and the query
  # under it could never be corrected. The route already knows better.
  #
  # Only where nothing in the query names an action: `?action=` is
  # priority 1 of the resolution order and the only way to reach a
  # second create-type action, so `/products/create?action=quick_add`
  # rebuilds as `/products?action=quick_add`, disagrees with the path
  # being served, and is left exactly as it came in.
  #
  # Last, and only over a socket nothing else has redirected, because
  # `push_patch/2` *raises* on a socket already set to redirect rather
  # than overruling it. A host patching from `after_handle_params/2` —
  # `/profile` to `/profile/<id>` — would otherwise be taken down by a
  # query string it never looked at.
  def canonicalize_query(socket, %URI{} = uri, base_path, ash_action) do
    canonical_base =
      if socket.assigns.live_action == :create and
           is_nil(socket.assigns.params.action),
         do: uri.path,
         else: base_path

    canonical_path = URLParams.full_path(canonical_base, socket.assigns.params)

    if ash_action && is_nil(socket.redirected) &&
         correctable_query?(uri, canonical_path) do
      # `replace: true`: Back belongs to wherever the visitor came
      # from, not to the URL they were just moved off.
      Phoenix.LiveView.push_patch(socket, to: canonical_path, replace: true)
    else
      socket
    end
  end

  # Whether `canonical_path` corrects `uri`'s query without moving the page.
  #
  # Public only because the generated `handle_params/3` calls it; it is an
  # internal detail of that callback rather than surface a host may rely on.
  #
  # Canonicalize the query, never the path. `full_path/2` rebuilds both, but
  # only the query is this function's to correct: the path it writes is from
  # the parsed params, and where that disagrees with the path actually being
  # served, rewriting it does not tidy the URL — it navigates.
  #
  # Two ways they disagree, both of them real:
  #
  #   * `?action=` is priority 1 of the action resolution order, and
  #     `quick_view/3` serves no `/<action>` route, so it is the only way to
  #     reach a second create-type action. `full_path/2` names it in the query
  #     over the base path, so `/products/create?action=quick_add` rebuilds as
  #     `/products?action=quick_add`, a different page.
  #   * An id the URL percent-encodes comes back raw from `full_path/2`, so the
  #     two never agree and the patch repeats forever.
  #
  # So the path is compared only to be left alone: when it differs, the URL came
  # in naming something this cannot rewrite, and is returned as typed.
  #
  # The query is compared as decoded maps, which is the only form the two sides
  # agree in — and a wrong comparison here is not a cosmetic bug but an endless
  # loop, since each patch is another request. Against the raw params map it
  # never settles: `URLParams` holds `limit` and `page` as integers where a query
  # holds strings.
  def correctable_query?(%URI{} = uri, canonical_path) when is_binary(canonical_path) do
    canonical = URI.parse(canonical_path)

    canonical.path == uri.path and
      URI.decode_query(uri.query || "") != URI.decode_query(canonical.query || "")
  end
end
