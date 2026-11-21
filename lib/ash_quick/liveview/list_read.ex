defmodule AshQuick.LiveView.ListRead do
  @moduledoc false
  # The list's read: which rows, in which order and which page of them, with
  # the fields its table draws loaded, and the first read of a page, which
  # reads it once more without a custom filter that raised.
  require Ash.Query
  require Logger
  import Phoenix.LiveView, only: [put_flash: 3]
  import Phoenix.Component, only: [assign: 3]
  use Gettext, backend: AshQuick.Gettext

  alias AshQuick.LiveView.CustomFilter
  alias AshQuick.LiveView.DetailsUtils
  alias AshQuick.LiveView.ListFilterGuard
  alias AshQuick.LiveView.URLParams
  alias AshQuick.LiveView.Utils
  alias AshQuick.LiveView.QuickView.Options

  # Timed as `[:ash_quick, :list, :read]` (see `AshQuick.Telemetry`), the
  # query's building with it: loading the fields is part of what a read costs.
  def load_data!(socket, %URLParams{} = params, %Options{} = options) do
    limit = params.limit
    offset = get_offset(params.page, limit)

    AshQuick.Telemetry.span(
      [:list, :read],
      %{
        quick_view: Map.get(socket, :view),
        resource: options.resource,
        action: socket.assigns.ash_action.name,
        scope: socket.assigns[:scope],
        page_number: params.page || 1,
        limit: limit,
        search?: params.search not in [nil, ""],
        custom_filter?: params.custom_filter != nil
      },
      fn ->
        page =
          socket
          |> list_query(params, options)
          |> Ash.Query.page(
            limit: limit,
            offset: offset,
            count: countable?(socket.assigns.ash_action)
          )
          |> Ash.read!()

        {page, %{rows: rows(page)}, %{}}
      end
    )
  end

  defp rows(%{results: results}) when is_list(results), do: length(results)
  defp rows(results) when is_list(results), do: length(results)

  def list_query(socket, %URLParams{} = params, %Options{} = options) do
    socket
    |> read_query(params, options)
    |> Utils.load_fields(options.list_fields, strict?: true)
    |> Ash.Query.load(options.load ++ options.list_load, strict?: true)
    # Not drawn as a column unless listed, but every row's checkbox is named
    # after it. An aggregate label needing a tenant the reader has not got is
    # skipped, not failing the whole read, and those rows' checkboxes are
    # named by id.
    |> Utils.load_display_label()
    |> then(
      &Ash.Query.load(
        &1,
        DetailsUtils.related_hint_load(options.resource, options.list_fields, &1.tenant)
      )
    )
    |> maybe_load_active(options.resource)
  end

  # Which rows, in which order: the list's read through its search, filters
  # and sort, loading nothing.
  def read_query(socket, %URLParams{} = params, %Options{} = options) do
    options.resource
    |> Ash.Query.for_read(
      socket.assigns.ash_action.name,
      Utils.lookup_input(options.resource, params.search),
      scope: socket.assigns.scope
    )
    |> maybe_apply_base_filter(options.base_filter)
    |> maybe_apply_filters(options.filters, params.selected_filters)
    |> maybe_apply_custom_filter(params.custom_filter, socket.assigns.scope, options)
    |> apply_sort(params, options)
  end

  # An action that counts on request (Ash's default, `countable true`) is asked
  # to, so its pager can say how many pages there are. One that declares
  # `countable false` refuses the request outright, and its list pages without
  # a total.
  defp countable?(%{pagination: %{countable: countable}}), do: countable != false
  defp countable?(_action), do: false

  defp maybe_apply_base_filter(query, nil), do: query
  defp maybe_apply_base_filter(query, base_filter), do: Ash.Query.filter(query, ^base_filter)

  defp maybe_apply_filters(query, _, []), do: query

  defp maybe_apply_filters(query, filters, [filter_name | rest]) do
    case Enum.find(filters, &(&1["name"] == filter_name)) do
      %{"expression" => expression} -> Ash.Query.filter(query, ^expression)
      _ -> query
    end
    |> maybe_apply_filters(filters, rest)
  end

  defp maybe_apply_custom_filter(query, nil, _scope, _options), do: query

  # On Day reads its date in the reader's zone, the one the list shows
  # timestamps in.
  defp maybe_apply_custom_filter(query, custom_filter, scope, options) do
    case CustomFilter.build_ash_filter(custom_filter,
           fields: row_fields(query, options),
           timezone: AshQuick.Scope.timezone(scope)
         ) do
      nil -> query
      ash_filter -> Ash.Query.filter_input(query, ash_filter)
    end
  end

  # The fields a row can name, the ones the list offers, whose types say how
  # some rows are asked: Is Empty on a string or a list, and a row comparing
  # a `Money`. `ListFilterGuard.drop_refused_rows/4` has dropped a row on any
  # other, and `build_ash_filter/2` reads none.
  defp row_fields(query, options), do: ListFilterGuard.listed_fields(query.resource, options)

  # A custom filter is the one part of this query a visitor authors, and there
  # is no asking in advance whether it works.
  # `ListFilterGuard.drop_refused_rows/4` has dropped every row on a field the
  # list does not offer, or by an operator the form does not offer, but a row
  # can still fail where nothing before the read sees it:
  #
  #   * a real field carrying a value its type cannot cast — which
  #     `filter_input/2` accepts, and the *data layer* refuses, as an
  #     `Ecto.Query.CastError`. `FilterForm` refuses such a value on Apply,
  #     under its row, by asking the field's type as Ash's filter does
  #     (`Ash.Type.coerce/3`), so a typed one never gets here. A link still
  #     can, written by hand;
  #   * anything else the data layer refuses that the form cannot know of.
  #
  # Each arrives the same way: raised by `Ash.read!` from inside
  # `handle_params/3`, taking the mount down rather than showing on the page.
  # The form's check is for the visitor, who is told which row was wrong; it
  # sees only what the form offers, and only the cast, not everything the data
  # layer will refuse. So the filter is not validated here — it is tried, and
  # this path stays the backstop for whatever reaches it.
  #
  # A read that raises with a filter applied is read once more without it. If
  # that succeeds the filter was the problem: it is dropped from the params the
  # whole page is built from, with a flash saying so, and the list, the export
  # query, the filter form and `full_path/2` all follow. If it raises too, the
  # filter was never the problem and that error stands — `base_filter`,
  # `filters` and `sort_by` are the host's own, and a bug in one should keep
  # raising loudly rather than become a flash a visitor can do nothing about.
  #
  # Neither is recognisable. An uncastable value reaches us as an
  # `Ash.Error.Unknown` whose `:error` is the data layer's
  # `Ecto.Query.CastError` already rendered to a string — the same struct a
  # bug in the read produces, so there is nothing to tell them apart. What the
  # rescue can say is that the error came from the read at all:
  # `ash_error?/1` lets a raise out of `load_data!/3`'s own pipeline keep
  # raising instead of being reported as the visitor's filter.
  #
  # Rescued either way means the flash can be wrong — a read that fails once and
  # succeeds on the retry gets it too — so the error is logged before the retry.
  #
  # The page is handed to `keep_live/4` as `:initial`, so this is the render's
  # one read rather than a probe in front of another one. Refetches re-run the
  # closure below, which closes over the corrected params.
  def initial_read(socket, %URLParams{custom_filter: nil} = params, %Options{} = options),
    do: {socket, params, load_data!(socket, params, options)}

  def initial_read(socket, %URLParams{} = params, %Options{} = options) do
    {socket, params, load_data!(socket, params, options)}
  rescue
    error ->
      if Ash.Error.ash_error?(error) do
        retry_without_filter(socket, params, options, error)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp retry_without_filter(socket, %URLParams{} = params, %Options{} = options, error) do
    # Never the filter's values: they are what the visitor typed (an email, a
    # name), and the data layer's cast error quotes them back, so each value is
    # redacted out of the messages. The start of a message stays, because it is
    # what tells a refused value from a host bug or a dropped connection; the
    # rest goes, because an error such as `InvalidFilterValue` goes on to
    # inspect the whole query, the actor and their email included. The field
    # names come from the URL too, so they are inspected, and a message is cut
    # to one line, or a newline in one would forge a log line. The frames are
    # each inner error's own: the rescue's trace is only where `Ash.read!`
    # re-raised, the same for every failure.
    values = CustomFilter.values(params.custom_filter)
    timed_out? = timed_out?(error)

    told =
      if timed_out?,
        do: "The visitor will be told the read took too long.",
        else:
          "The visitor will be told the filter was refused, whether or not that is what this error means."

    Logger.warning("""
    AshQuick is re-reading #{inspect(options.resource)} without the custom \
    filter the URL carried, which raised. #{told}

    Filtered fields: #{Enum.map_join(CustomFilter.field_names(params.custom_filter), ", ", &inspect/1)}
    Errors:

    #{Enum.map_join(inner_errors(error), "\n", &raised_at(&1, values))}\
    """)

    if timed_out? do
      # The filter was read, and too slowly: the list is read without it,
      # as any other, but the visitor is told so, and the filter form opens
      # holding the filter, to narrow it rather than write it again.
      held = params.custom_filter
      params = %URLParams{params | custom_filter: nil, show_custom_filter: true}

      {socket |> put_flash(:error, timed_out_message()) |> assign(:held_filter, held), params,
       load_data!(socket, params, options)}
    else
      params = %URLParams{params | custom_filter: nil}

      {put_flash(socket, :error, ListFilterGuard.refused_filter_message()), params,
       load_data!(socket, params, options)}
    end
  end

  defp timed_out_message,
    do:
      gettext(
        "Reading the list with that filter took too long, so the list shows unfiltered. Narrow the filter and apply it again."
      )

  # Whether the read failed for taking too long, rather than for the
  # filter: Postgres cancelling it at its `statement_timeout`. It reaches the
  # rescue as Ash's unknown error around Postgrex's own, which may be
  # rendered to text by then. A connection error is not one: the pool says
  # `connection is closed because of an error, disconnect or timeout` for a
  # dropped connection as for one that ran out of time, and the visitor is
  # not told a filter took too long over a disconnect. The module is named
  # rather than matched: AshQuick does not depend on Postgrex.
  @doc false
  def timed_out?(error) do
    error
    |> inner_errors()
    |> Enum.any?(&(&1 |> Map.get(:error) |> timeout_cause?()))
  end

  defp timeout_cause?(%{__struct__: Postgrex.Error, postgres: %{code: :query_canceled}}),
    do: true

  defp timeout_cause?(message) when is_binary(message),
    do:
      message =~ "canceling statement due to statement timeout" or
        message =~ "(query_canceled)"

  defp timeout_cause?(_cause), do: false

  defp inner_errors(error) do
    case Ash.Error.to_error_class(error) do
      %{errors: [_ | _] = errors} -> errors
      class -> [class]
    end
  end

  @message_length 160

  defp raised_at(error, values) do
    "#{inspect(error.__struct__)}: #{summary(error, values)}\n#{frames(error)}"
  end

  # The message without Ash's bread crumbs, values redacted, on one line and cut
  # short of whatever context the error inspects after it.
  defp summary(error, values) do
    summary =
      error
      |> Exception.message()
      |> redact(values)
      |> String.split("\n")
      |> Enum.reject(&(String.trim(&1) in ["", "Bread Crumbs:"] or bread_crumb?(&1)))
      |> Enum.join(" ")

    if String.length(summary) > @message_length,
      do: String.slice(summary, 0, @message_length) <> "…",
      else: summary
  end

  defp bread_crumb?(line), do: String.starts_with?(String.trim_leading(line), "> ")

  defp frames(%{stacktrace: %{stacktrace: [_ | _] = frames}}),
    do: Exception.format_stacktrace(frames)

  defp frames(_error), do: "    (no stack trace)\n"

  @redacted "[filter value]"

  # Quoted wherever it appears; bare only from four characters up, below which
  # it would be cut out of words and numbers the message needs. A value that
  # short identifies no one.
  defp redact(message, values) do
    Enum.reduce(values, message, fn value, message ->
      message = String.replace(message, inspect(value), @redacted)

      if String.length(value) >= 4,
        do: String.replace(message, value, @redacted),
        else: message
    end)
  end

  # A column the visitor sorted by goes first, then the QuickView's `sort_by`,
  # then the action's own sort, each ordering the rows the one before ties on;
  # Ash ends every paginated read with the primary key, so ties left after all
  # of them keep their order across pages. The column goes through
  # `sort_input/3`, as a visitor's input: Ash refuses a private field there,
  # and authorizes it against field policies. Prepending it shifts the indices
  # Ash keeps of input sorts, so `sort_by` is not authorized as one.
  defp apply_sort(query, %URLParams{} = params, %Options{} = options) do
    query = maybe_apply_sort(query, options.sort_by)

    case URLParams.sort_input(params) do
      nil -> query
      sort -> Ash.Query.sort_input(query, sort, prepend?: true)
    end
  end

  defp maybe_apply_sort(query, nil), do: query
  defp maybe_apply_sort(query, sort_by), do: Ash.Query.sort(query, sort_by, prepend?: true)

  defp maybe_load_active(query, resource) do
    case AshQuick.Info.activation(resource) do
      nil -> query
      %{attribute: attribute} -> Ash.Query.load(query, attribute, strict?: true)
    end
  end

  def get_offset(nil, _), do: 0
  def get_offset(page, limit), do: (page - 1) * limit
end
