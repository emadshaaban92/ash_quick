defmodule AshQuick.LiveView.Liveness do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias AshQuick.Config
  alias AshQuick.LiveView.Liveness.Graph
  alias AshQuick.LiveView.QuickView.Options
  alias AshQuick.LiveView.URLParams

  @doc """
  `AshPhoenix.LiveView.keep_live/4` options for a list assign.

  Empty for a resource that publishes nothing — the page is simply not live.
  """
  def list_options(%Options{} = options) do
    build(options, &record_ids/1)
  end

  @doc """
  `AshPhoenix.LiveView.keep_live/4` options for a details assign.

  A record that came back `nil` — absent, or unreadable for this actor — offers
  no id to scope by, but the id in the URL names the record the page is about
  either way, so the page still wakes up if the record becomes readable.
  """
  def details_options(%Options{} = options, %URLParams{id: id}) do
    build(options, fn
      nil -> [id]
      result -> record_ids(result)
    end)
  end

  # Whether a view is live is the resource's call, not the view's: the
  # `ash_quick.liveness` block decides who publishes, and a QuickView listens
  # exactly when there is something to hear. `liveness_options` only tunes it.
  defp build(%Options{resource: resource} = options, ids_fun) do
    case AshQuick.Topics.enabled?(resource) do
      true -> live_options(options, ids_fun)
      false -> []
    end
  end

  # Topics are derived, never named: `AshQuick.Topics` is what the publishing
  # side uses too, so a page cannot listen on a topic the resource does not
  # publish. `:extra_records` returns `{resource, id}` pairs for the same reason
  # — a topic spelled out by hand can disagree with the one published, and
  # nothing at runtime would say so.
  #
  # `recursive?` is how far the derivation reaches: `false` stops at the records
  # in the assign, `true` follows every relationship they materialized. Both
  # topics are published — Ash expands `publish_all [[:id, nil]]` into both
  # "product:<id>" and the bare "product", the `nil` alternative dropping the id
  # segment.
  defp live_options(%Options{resource: resource, liveness_options: liveness}, ids_fun) do
    {recursive?, liveness} = Keyword.pop(liveness, :recursive?, true)
    {extra_records, liveness} = Keyword.pop(liveness, :extra_records, nil)
    liveness = Keyword.put_new(liveness, :refetch_window, Config.refetch_window())

    case liveness[:subscribe] do
      subscribe when is_function(subscribe, 1) ->
        liveness

      _ ->
        Keyword.put(
          liveness,
          :subscribe,
          &topics(&1, recursive?, resource, ids_fun, extra_records)
        )
    end
  end

  defp topics(result, recursive?, resource, ids_fun, extra_records) do
    own = own_topics(result, recursive?, resource, ids_fun)

    Enum.uniq(own ++ extra_record_topics(result, extra_records))
  end

  defp own_topics(result, false, resource, ids_fun),
    do: for(id <- ids_fun.(result), do: AshQuick.Topics.record(resource, id))

  # A details page whose record read back nil offers no graph to walk, but the
  # id in the URL names the record the page is about either way, so the page
  # still wakes up if the record becomes readable.
  defp own_topics(result, true, resource, ids_fun) do
    case Graph.walk(result) do
      {[], _skipped} -> own_topics(result, false, resource, ids_fun)
      {watchable, _skipped} -> for {res, id} <- watchable, do: AshQuick.Topics.record(res, id)
    end
  end

  # The hook hands back records or `{resource, id}` pairs, never topics, so the
  # one function that spells a topic out stays `AshQuick.Topics`.
  defp extra_record_topics(_result, nil), do: []

  defp extra_record_topics(result, fun) do
    result
    |> fun.()
    |> List.wrap()
    |> Enum.map(fn
      {resource, id} -> AshQuick.Topics.record(resource, id)
      %resource{id: id} -> AshQuick.Topics.record(resource, id)
    end)
  end

  @doc """
  Refuses at compile time to build a view whose liveness cannot work.

  A subscription is only as good as the publication behind it, and nothing at
  runtime reports the difference: an unpublished topic is a page that quietly
  never updates. So it is refused at build time instead.

  Liveness follows the resource, so a view on a silent resource is not an error
  — it is simply not live. Tuning liveness there is, since the options would
  have nothing to act on.
  """
  def verify_publishable!(%Options{resource: resource, liveness_options: liveness}, module) do
    publishes? = AshQuick.Topics.enabled?(resource)

    cond do
      liveness != [] and not publishes? ->
        raise """
        #{inspect(module)} tunes `liveness_options`, but #{inspect(resource)} publishes \
        nothing — so the options have nothing to act on and the view is not live.

        Add the extension that publishes it, and leave liveness enabled:

            use Ash.Resource, extensions: [AshQuick]
        """

      publishes? and is_nil(AshQuick.Config.endpoint()) ->
        raise """
        #{inspect(module)} is live on #{inspect(resource)}, but no `:endpoint` is \
        configured, so nothing is published.

            config :ash_quick, endpoint: MyAppWeb.Endpoint
        """

      true ->
        :ok
    end
  end

  @doc """
  What this socket is listening to, and what it passed over.

  The topic set is derived from the data, so it differs per actor and per row —
  two users on the same page hold different sets, and the only honest answer to
  "what is this page watching?" is a runtime one. `:skipped` counts the records
  found behind a resource that publishes nothing, which turns "should this
  resource publish?" into a question with an answer.
  """
  def explain(socket) do
    config = live_config(socket)

    subscribed =
      config |> Map.values() |> Enum.flat_map(&(&1[:subscribed_topics] || [])) |> Enum.uniq()

    # An assign holding no subscription has nothing to say about what it passed
    # over. That is how a released assign drops out: `unsubscribe_all/2` empties
    # its topics but leaves the entry, and its data stays in the socket, so
    # walking it would count records this page no longer watches. A silent
    # resource keeps its `nil` — it never had a subscription to release, and
    # what it skipped is the whole point of asking.
    skipped =
      config
      |> Enum.reject(fn {_assign, entry} -> entry[:subscribed_topics] == [] end)
      |> Enum.reduce(%{}, fn {assign, _entry}, acc ->
        {_watchable, skipped} = socket.assigns |> Map.get(assign) |> Graph.walk()
        Map.merge(acc, skipped, fn _resource, a, b -> a + b end)
      end)

    %{subscribed: subscribed, skipped: skipped}
  end

  @doc """
  Drops every topic this socket holds through `keep_live`.

  Runs before each `handle_params`, since the next params want their own set.
  The topics are computed from the fetched data, so `keep_live`'s own config is
  the only record of what is subscribed — and so it is also what has to be
  emptied here. `keep_live` replaces only the assign it is handed, and one
  QuickView serves both the list and the details action, so an entry for the
  action we are leaving would otherwise survive with the topics it held: read
  back by `explain/1` as still subscribed, and diffed against by `resync/3` and
  by `AshPhoenix.LiveView.handle_live/4` as if they were.

  The entries themselves stay. A details `keep_live(:record)` can outlive a
  patch to a form, which runs no `keep_live` of its own, and its deferred
  refetch still needs the callback and options recorded here.
  """
  def unsubscribe_all(socket, %Options{} = options) do
    pub_sub = options.liveness_options[:pub_sub] || socket.endpoint
    config = live_config(socket)

    config
    |> Map.values()
    |> Enum.flat_map(&(&1[:subscribed_topics] || []))
    |> Enum.uniq()
    |> Enum.each(&pub_sub.unsubscribe(&1))

    assign(
      socket,
      :ash_live_config,
      Map.new(config, fn {assign, entry} -> {assign, %{entry | subscribed_topics: []}} end)
    )
  end

  @doc """
  Re-scopes the subscription to the records now held in `assign`.

  A row, bulk or details action reloads the assign itself rather than going
  through `AshPhoenix.LiveView.handle_live/3`, which is where the topic set is
  normally diffed — without this, acting on a row that then leaves the list
  would leave the socket listening to it and deaf to whichever row took its
  place.

  All three publish — a bulk action announces each row it writes exactly as a
  row action announces its one — so none of them is deaf; each only defers the
  repair, and the deferral is the reason to re-scope here. An action writes its
  own record, so the notification it publishes does eventually reach a topic
  this socket holds — but `refetch_window` coalesces it, so for that window the
  page is scoped to the graph as it was *before* the action. Approving a product
  from its details page fills `reviewed_by`, a user the page was not holding a
  moment earlier and would not hear from until the refetch lands.

  This covers the actions AshQuick itself runs. A host QuickView that assigns
  the record from a handler of its own has to call this after it.
  """
  def resync(socket, assign, %Options{} = options) do
    resync_config(socket, assign, live_config(socket)[assign], options)
  end

  defp resync_config(socket, _assign, nil, _options), do: socket

  defp resync_config(socket, assign, config, _options) do
    case config.opts[:subscribe] do
      subscribe when is_function(subscribe, 1) ->
        pub_sub = config.opts[:pub_sub] || socket.endpoint
        new_topics = socket.assigns |> Map.get(assign) |> subscribe.() |> List.wrap()
        old_topics = config[:subscribed_topics] || []

        Enum.each(old_topics -- new_topics, &pub_sub.unsubscribe(&1))
        Enum.each(new_topics -- old_topics, &pub_sub.subscribe(&1))

        assign(
          socket,
          :ash_live_config,
          Map.put(live_config(socket), assign, %{config | subscribed_topics: new_topics})
        )

      _ ->
        socket
    end
  end

  defp live_config(socket), do: Map.get(socket.assigns, :ash_live_config) || %{}

  defp record_ids(%page{results: results}) when page in [Ash.Page.Offset, Ash.Page.Keyset],
    do: record_ids(results)

  defp record_ids(results) when is_list(results), do: Enum.map(results, & &1.id)
  defp record_ids(%{id: id}), do: [id]
  defp record_ids(_), do: []
end
