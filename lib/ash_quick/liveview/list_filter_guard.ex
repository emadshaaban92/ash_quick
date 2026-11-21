defmodule AshQuick.LiveView.ListFilterGuard do
  @moduledoc false
  # What of a custom filter the list refuses before its read, and the fields
  # the filter may name: the ones the list offers, less those a field policy
  # hides from the visitor.
  import Phoenix.LiveView, only: [put_flash: 3]
  use Gettext, backend: AshQuick.Gettext

  alias AshQuick.LiveView.Components.FilterForm
  alias AshQuick.LiveView.CustomFilter
  alias AshQuick.LiveView.FilterField
  alias AshQuick.LiveView.LocalDatetime
  alias AshQuick.LiveView.URLParams
  alias AshQuick.LiveView.QuickView.Options

  # Names no field, because the field is not always the part that was wrong —
  # an unusable value on a perfectly good field lands here too. A visitor who
  # typed the filter knows which one they typed, and a visitor who was handed
  # the link cannot act on the name either way.
  def refused_filter_message,
    do: gettext("That filter couldn't be applied to this list, so it was ignored.")

  @doc """
  What a filter past the bounds a list reads one in is answered with where
  the visitor built it, in the form or a cell's menu: what to do about it.
  A link past them gets `refused_filter_message/0`, as any refused link.
  """
  def too_large_message,
    do:
      gettext(
        "That filter is too large to apply. Remove some conditions or values and try again."
      )

  def listed_fields(resource, options),
    do:
      resource
      |> CustomFilter.filterable_fields(options.list_filterable)
      |> Map.new(&{&1.name, &1})

  defp emptiness_rows(filter),
    do:
      filter
      |> CustomFilter.leaves()
      |> Enum.filter(&(CustomFilter.value_shape(&1.operator) == :none))

  # A row on a field a field policy hides from the actor on every record is
  # dropped before the read, the way `FilterForm` leaves the field out: Ash
  # would read the field as `nil`, so the list would come back empty under a
  # filter that looked like an answer. Only a link carries one, written for an
  # actor who could see the field or by hand, so the visitor is told, and the
  # address bar is corrected with the rest of `:params`.
  #
  # So is Is Empty or Is Not Empty on a field hidden from the actor on only
  # some records, which `FilterForm` does not offer on it: Ash reads the field
  # as `nil` where it is hidden, so Is Empty would keep a row whose value the
  # actor may not see as one that has none.
  #
  # And so is On Day with a value it cannot read as a day in the list's zone:
  # one that is no date, or any date when the zone will not load. The filter
  # it builds leaves such a row out, and the visitor is told here why.
  #
  # And so is Has Any Of on a field that holds no list, which asks the data
  # layer for something it does not have: Postgres would refuse the read with
  # an error, logged before the list is read again without the filter.
  #
  # And so is a row on a field the list does not offer, which the form does
  # not offer either: one the QuickView's `filterable:` leaves out, as the
  # host named the fields this list may be filtered by, most likely the ones
  # its table has indexes for, or without `filterable:` one the filter takes
  # no type of, or that is no field at all. A row through a relationship,
  # `"brand.name"`, is dropped unless `filterable:` names it, so a link can
  # reach no related field, nor go further, by itself. Ash's filter input
  # reads a relationship's name as one to filter through, so a row naming
  # `brand` with `name` as its operator would otherwise do just that.
  #
  # And so is a row comparing by an operator the form does not offer, or with
  # a value its operator cannot take, `CustomFilter.readable?/1`: Ash's filter
  # input reads any name where an operator goes, and a list where one value
  # goes as something else again. And one holding a key path on a field that
  # is no map, or none on a map, which the form never writes either.
  #
  # A root left with no rows, as one a hand-written link wrote as a single
  # row is, leaves no filter at all.
  #
  # A filter past the bounds a list reads one in, which only a link carries,
  # was dropped as the URL was read (`CustomFilter.within_bounds?/1`), and
  # the visitor is told here.
  def drop_refused_rows(
        socket,
        %URLParams{custom_filter_refused?: true} = params,
        _action,
        _options
      ),
      do: {put_flash(socket, :error, refused_filter_message()), params}

  def drop_refused_rows(socket, %URLParams{custom_filter: nil} = params, _action, _options),
    do: {socket, params}

  def drop_refused_rows(socket, %URLParams{custom_filter: filter} = params, action, options) do
    scope = socket.assigns[:scope]
    by_name = listed_fields(options.resource, options)

    names = CustomFilter.field_names(filter)
    hidden = hidden_fields(names, by_name, action, scope) ++ unoffered_fields(names, by_name)

    partly_hidden =
      case filter |> emptiness_rows() |> Enum.map(& &1.field_name) |> Enum.uniq() do
        [] -> []
        names -> hidden_fields(names, by_name, action, scope, filter_is: false)
      end

    # A group whose rows were all removed is a leaf to `leaves/1`, and
    # filters by nothing, so it is never refused.
    refused? = &(not CustomFilter.group?(&1) and refused_row?(&1, partly_hidden, by_name, scope))

    case {hidden, filter |> CustomFilter.leaves() |> Enum.filter(refused?)} do
      {[], []} ->
        {socket, params}

      _ ->
        filter =
          filter
          |> CustomFilter.reject_fields(hidden)
          |> CustomFilter.reject_rows(refused?)
          |> unless_emptied()

        {put_flash(socket, :error, refused_filter_message()),
         %URLParams{params | custom_filter: filter}}
    end
  end

  # A root left with no rows by the drop leaves no filter at all, and no
  # filter in the URL: a link's root that was one row is that row in a group.
  defp unless_emptied(%CustomFilter{children: []}), do: nil
  defp unless_emptied(filter), do: filter

  # The fields the filter offers this visitor, by name: the ones the
  # QuickView's `filterable:` names, or every one the form can take, less those
  # field policies hide from the visitor. Asked on every navigation, as the
  # list's columns are; the answer only changes with the scope.
  def offered_fields(socket, action, %Options{} = options) do
    options.resource
    |> CustomFilter.offered_fields(options.list_filterable, action, socket.assigns[:scope])
    |> Enum.map(& &1.spec)
  end

  defp unoffered_fields(names, by_name), do: Enum.reject(names, &Map.has_key?(by_name, &1))

  # Whether `row` is refused by its operator: one the form does not offer, or
  # with a value it cannot take, Is Empty on a field hidden on some rows, On
  # Day on no day, and Has Any Of on a field holding no list. Or by its key
  # path: one on a field that is no map, or none on one that is.
  defp refused_row?(row, partly_hidden, by_name, scope) do
    case CustomFilter.readable?(row) and fits?(row, by_name) and
           CustomFilter.value_shape(row.operator) do
      false -> true
      :none -> row.field_name in partly_hidden
      :day -> unreadable_day?(row, scope)
      :list -> row.operator == "has_any" and not list_row?(row, by_name)
      _ -> false
    end
  end

  # Whether a row holds a key path exactly when its field is a map, and
  # compares any other field by an operator the form offers on it. A name the
  # list does not offer is refused with its field.
  defp fits?(%CustomFilter{field_name: name} = row, by_name) do
    case by_name[name] do
      nil -> true
      field -> CustomFilter.fits?(row, field) and offered_operator?(row, field)
    end
  end

  # Ash's filter input takes any of its operators on any field, so a link
  # could ask `Active > Yes` or `Name` on a day, which the form never
  # writes: Ash reads some as something else again, and the data layer
  # refuses others, which costs the list a second read. A row is held to
  # the operators its field offers in the form, Is Empty and Is Not Empty
  # included, and Any Of on any field compared by Equals, which a link can
  # write and the form shows as typed values. A record row and a map row
  # are held to theirs by `CustomFilter.fits?/2` and
  # `CustomFilter.readable?/1`.
  defp offered_operator?(%CustomFilter{path: path}, _field) when is_list(path), do: true
  defp offered_operator?(_row, %FilterField{record?: true}), do: true

  defp offered_operator?(%CustomFilter{operator: operator}, %FilterField{field: field}) do
    operators = FilterForm.offered_operators(field)
    operator in operators or (operator == "in" and "equals" in operators)
  end

  # Whether a row names a field holding a list. A row left without a value
  # filters by nothing, and a name the list does not offer is refused with
  # its field, so neither is refused here.
  defp list_row?(%CustomFilter{field_name: name} = row, by_name) do
    case by_name[name] do
      %{field: %{type: {:array, _type}}} -> true
      nil -> true
      _field -> not CustomFilter.applied?(row)
    end
  end

  # A row left without a value filters by nothing, and is not refused.
  defp unreadable_day?(%CustomFilter{value: value} = row, scope) do
    CustomFilter.applied?(row) and
      LocalDatetime.day_range(value, AshQuick.Scope.timezone(scope)) == :error
  end

  # Those of `names` that are fields a row can name, `by_name`, the actor may
  # not see: on every record, or with `filter_is: false` on some. A name the
  # list does not offer is refused by `unoffered_fields/2`.
  def hidden_fields(names, by_name, action, scope, opts \\ []) do
    named = Enum.filter(names, &(is_binary(&1) and Map.has_key?(by_name, &1)))

    visible =
      named
      |> Enum.map(&by_name[&1])
      |> CustomFilter.visible(action, scope, opts)
      |> MapSet.new(& &1.name)

    Enum.reject(named, &MapSet.member?(visible, &1))
  end
end
