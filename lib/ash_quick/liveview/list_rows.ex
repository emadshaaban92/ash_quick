defmodule AshQuick.LiveView.ListRows do
  @moduledoc false
  # Rows hold their place
  # ---------------------
  #
  # Nothing on a live list moves unless its reader asks: a row that shifted
  # under the pointer is a click or a tick on the wrong record. So a refetch
  # re-reads the rows already on screen, by id, with the list's own search and
  # filters and through the reader's scope, and puts each back in its slot.
  #
  # A row that does not come back keeps its slot as a placeholder: no data, no
  # link, no checkbox, only "No longer available". That one wording covers a
  # row destroyed, one edited out of the filter and one the reader may no
  # longer read: why a record left is not the reader's to know, and telling
  # the last two apart would mean reading past the reader's policies.
  #
  # A record that would now belong on the page but is not on it — created
  # elsewhere, or edited into the filter — is announced, not inserted: a bar
  # over the table offers a Reload, which reads the list afresh from its URL.
  # Whether there is one is asked of the reader's own read of their page (see
  # `news?/6`), so a record they may not read never raises the bar.
  #
  # The reader's own actions are the exception, being what they asked for: a
  # row action returns through its modal to a fresh read, and a bulk run reads
  # the list afresh, so a queue the reader works through closes up.
  #
  # `:row_order` is the screen: the ids drawn, in the order drawn, the
  # placeholders' among them. `:data` holds only the records still read back,
  # so everything that acts on rows — selection, bulk runs, row menus, export —
  # sees none of the placeholders.
  require Ash.Query
  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias AshQuick.LiveView.ListRead

  @no_pending %{refresh?: false, candidates: %{}}

  def fresh_screen(page) do
    %{
      row_order: Enum.map(page.results, & &1.id),
      gone_rows: MapSet.new(),
      list_news: false,
      list_pending: @no_pending
    }
  end

  # The rows on screen that are not placeholders yet, read again and put back
  # in screen order. Which of them did not come back is `after_refetch/4`'s to
  # work out, since the refetch callback can only return the page.
  defp read_rows!(socket, params, options, order, gone) do
    case Enum.reject(order, &MapSet.member?(gone, &1)) do
      [] ->
        []

      ids ->
        by_id =
          socket
          |> ListRead.list_query(params, options)
          |> Ash.Query.filter(id in ^ids)
          |> Ash.Query.page(limit: length(ids), offset: 0, count: false)
          |> Ash.read!()
          |> Map.fetch!(:results)
          |> Map.new(&{&1.id, &1})

        for id <- order, record = by_id[id], do: record
    end
  end

  # What a refetch reads depends on what woke it. A row on screen, or a record
  # one of them shows, re-reads the rows; a record off screen only asks whether
  # the bar should go up. Woken by nothing it recorded (a host's own
  # `handle_live/4`), it re-reads the rows.
  def refetch_rows(socket, params, options) do
    %{data: data, row_order: order, gone_rows: gone, list_pending: pending} = socket.assigns

    if pending.refresh? or pending.candidates == %{} do
      %{data | results: read_rows!(socket, params, options, order, gone)}
    else
      data
    end
  end

  def after_refetch(page, socket, params, options) do
    %{row_order: order, list_pending: pending} = socket.assigns
    back = MapSet.new(page.results, & &1.id)

    gone = for id <- order, not MapSet.member?(back, id), into: MapSet.new(), do: id

    news? =
      socket.assigns.list_news or
        (pending.candidates != %{} and
           news?(socket, params, options, order, gone, pending.candidates))

    socket
    |> assign(gone_rows: gone, list_news: news?, list_pending: @no_pending)
    |> keep_to_shown_rows(back)
  end

  # Whether a record this page was told about, and is not showing, now belongs
  # on it. Asked of the reader's own read of the page they are on (its offset
  # and limit), so a record they may not read never counts.
  #
  # A created record on that page is new. An updated one may only have moved
  # up from the next page because a row above it left, which is no news at
  # all, so it counts only where a move-up cannot explain it: sorted in among
  # the rows still shown, or on a page that was the last when drawn, which had
  # no next page to move up from. What that leaves out — an edit that sorts a
  # record onto the very end of a full page — waits for the next navigation.
  defp news?(socket, params, options, order, gone, candidates) do
    fresh = page_ids(socket, params, options)
    shown = order |> Enum.reject(&MapSet.member?(gone, &1)) |> MapSet.new()

    last_shown =
      fresh
      |> Enum.with_index()
      |> Enum.flat_map(fn {id, at} -> if MapSet.member?(shown, id), do: [at], else: [] end)
      |> Enum.max(fn -> -1 end)

    last_page? = length(order) < params.limit

    fresh
    |> Enum.with_index()
    |> Enum.any?(fn {id, at} ->
      case candidates do
        %{^id => :create} -> true
        %{^id => :update} -> last_page? or at < last_shown
        _not_told -> false
      end
    end)
  end

  # The ids on the reader's page, and nothing else: no loads, no count.
  defp page_ids(socket, params, options) do
    socket
    |> ListRead.read_query(params, options)
    |> Ash.Query.select([:id])
    |> Ash.Query.page(
      limit: params.limit,
      offset: ListRead.get_offset(params.page, params.limit),
      count: false
    )
    |> Ash.read!()
    |> Map.fetch!(:results)
    |> Enum.map(& &1.id)
  end

  # A tick on a row no longer shown would keep the bulk menu open over nothing,
  # and "all" stays ticked only while every row shown still is.
  defp keep_to_shown_rows(socket, shown) do
    selected_rows = Map.get(socket.assigns, :selected_rows, %{})

    selected =
      for {id, "on"} <- selected_rows, MapSet.member?(shown, id), into: %{}, do: {id, "on"}

    selected =
      if selected_rows["all"] == "on" and MapSet.size(shown) > 0 and
           map_size(selected) == MapSet.size(shown),
         do: Map.put(selected, "all", "on"),
         else: selected

    row_actions =
      case Map.get(socket.assigns, :row_actions) do
        %{id: id} = open -> if(MapSet.member?(shown, id), do: open)
        nil -> nil
      end

    assign(socket, selected_rows: selected, row_actions: row_actions)
  end

  # A notification is noted before the refetch it may defer, so a coalesced
  # refetch still knows everything that woke it. One heard on the resource's
  # bare topic names its record: on screen, it refreshes that row; off screen,
  # or shown as "No longer available", a create or an update makes it a
  # candidate for the bar — a row edited back into the search comes back
  # through Reload. A destroy off screen adds nothing. One heard on a record's
  # own topic is a record a row shows, whatever its resource: the list holds no
  # row's own topic, and a category's parent arrives on both, where the bare
  # topic's copy alone would only make it a candidate.
  def note_notification(socket, topic, %Ash.Notifier.Notification{} = notification, options) do
    current = socket.assigns.list_pending

    pending =
      case notification do
        %{resource: resource, data: %{id: id}} when resource == options.resource ->
          if topic == AshQuick.Topics.collection(resource),
            do: note_own(current, id, notification, socket.assigns),
            else: %{current | refresh?: true}

        _related ->
          %{current | refresh?: true}
      end

    # Unchanged means either nothing to do, or a refetch already deferred that
    # will do it.
    if pending == current,
      do: :ignore,
      else: {:ok, assign(socket, :list_pending, pending)}
  end

  defp note_own(pending, id, notification, %{row_order: order, gone_rows: gone} = assigns) do
    cond do
      id in order and not MapSet.member?(gone, id) -> %{pending | refresh?: true}
      assigns.list_news -> pending
      true -> note_candidate(pending, id, notification)
    end
  end

  defp note_candidate(pending, id, %{action: %{type: type}}) when type in [:create, :update],
    do: %{pending | candidates: Map.update(pending.candidates, id, type, &max_kind(&1, type))}

  defp note_candidate(pending, _id, _destroy), do: pending

  # Created and then edited inside one window is still a create.
  defp max_kind(:create, _type), do: :create
  defp max_kind(_kind, type), do: type
end
