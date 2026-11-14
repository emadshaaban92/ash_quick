defmodule AshQuick.LiveView.CellFilter do
  @moduledoc false
  # Filtering a list by what one of its cells holds: the small menu on a cell
  # offers to keep only the rows holding the same value, or to drop them, and
  # each choice adds one row to the list's filter beside what it already
  # filters by (`and_also/2`).
  #
  # A cell offers this only where its column shows a field the list's filter
  # already offers this visitor (`columns/4`): the column's own field, as the
  # filter form names it, `"brand.name"` for a brand's name, so what the chip
  # then says is what the visitor clicked, and a host configures nothing new.
  # A `sensitive?` field, and one field policies hide from the visitor, is
  # offered by neither.
  #
  # What a choice compares with is read off the record on the page, by the
  # server, when the choice is picked: the menu sends only the row's id, the
  # column and which choice it was, so nothing the browser sends is the value.
  # `choices/4` answers both the menu and the click, so the two always agree.

  use Gettext, backend: AshQuick.Gettext

  alias AshQuick.LiveView.Components.FilterForm
  alias AshQuick.LiveView.CustomFilter
  alias AshQuick.LiveView.FilterField
  alias AshQuick.LiveView.QuickField
  alias AshQuick.LiveView.StoredMap

  # How many choices a list cell offers, one per item, and a map cell, one per
  # key: more would make a menu longer than the cell is wide is useful.
  @max_items 8
  @max_pairs 6

  # A map's value longer than this is not offered: a key holding a paragraph
  # is not what anyone filters by.
  @max_pair_value 120

  # How much of a value a menu entry shows.
  @label_length 32

  defmodule Choice do
    @moduledoc false
    # One entry of a cell's menu: `kind` says how it reads (`:only` keeps the
    # rows holding the value, `:out` drops them, `:item` keeps those whose
    # list holds an item, `:pair` those whose map holds a value at a key), and
    # `operator`, `value` and `path` are the filter row it adds. `shown` is
    # the value as the entry shows it, for an item or a map's key.
    @enforce_keys [:kind, :operator, :value]
    defstruct [:kind, :operator, :value, :path, :shown]
  end

  @doc """
  The list's columns a cell menu is offered on, by `QuickField.data_field/1`,
  each as `%{filter_field: filter_field, emptiness?: true}`, the
  `FilterField` its filter row names, and whether its cells may offer Is
  Empty: those of `fields`, the columns drawn, whose field `filterable`, the
  fields the filter offers this visitor as `filterable:` names them, holds.
  None when the list offers no filter.

  `partly_hidden` names the columns whose field a field policy hides on some
  of the visitor's rows: Ash reads it as `nil` where it is hidden, so the
  list refuses Is Empty and Is Not Empty on it, and its cells offer neither.
  """
  def columns(fields, resource, filterable, partly_hidden \\ [])

  def columns(fields, resource, filterable, partly_hidden)
      when is_list(filterable) and filterable != [] do
    offered = resource |> CustomFilter.filterable_fields(filterable) |> Map.new(&{&1.name, &1})

    for field <- fields,
        name = QuickField.data_field(field),
        filter_field = offered[name],
        into: %{},
        do: {name, %{filter_field: filter_field, emptiness?: name not in partly_hidden}}
  end

  def columns(_fields, _resource, _filterable, _partly_hidden), do: %{}

  @doc """
  What a cell holding `value`, of the column `filter_field` names, offers:

    * an empty cell, Is Empty and Is Not Empty;
    * a list, Has Any Of each of its first items;
    * a stored map, Equals for each of its first keys holding a short value,
      and for each key of a small map nested one level below;
    * a timestamp, On Day of the day the reader's `timezone` puts it on;
    * any other value, Equals and Not Equals, where its field compares so.

  Nothing for a value a field policy hides, a `sensitive?` mask, or one the
  field's type would not read back as written: a float, which the filter
  compares only by range, is offered neither. With `emptiness?: false` in
  `opts`, as `columns/4` gives a column, an empty cell offers nothing.
  """
  def choices(filter_field, value, timezone, opts \\ [])

  def choices(%FilterField{} = filter_field, value, timezone, opts) do
    operators = FilterForm.offered_operators(filter_field.field)

    operators =
      if Keyword.get(opts, :emptiness?, true),
        do: operators,
        else: operators -- ~w(is_nil is_not_nil)

    filter_field
    |> candidates(value, operators, timezone)
    |> Enum.filter(&readable?(&1, filter_field, timezone))
  end

  def choices(_filter_field, _value, _timezone, _opts), do: []

  defp candidates(_field, %Ash.ForbiddenField{}, _operators, _timezone), do: []
  defp candidates(_field, _value, [], _timezone), do: []

  defp candidates(%FilterField{} = field, value, _operators, _timezone)
       when is_non_struct_map(value) do
    if CustomFilter.map_field?(field), do: pairs(value), else: []
  end

  defp candidates(%FilterField{} = field, value, operators, _timezone)
       when value in [nil, "", []] do
    if CustomFilter.map_field?(field) or "is_nil" not in operators,
      do: [],
      else: [
        %Choice{kind: :only, operator: "is_nil", value: ""},
        %Choice{kind: :out, operator: "is_not_nil", value: ""}
      ]
  end

  defp candidates(_field, values, operators, _timezone) when is_list(values) do
    items =
      for item <- Enum.uniq(values),
          "has_any" in operators,
          text = text(item),
          is_binary(text),
          do: %Choice{kind: :item, operator: "has_any", value: [text], shown: item}

    Enum.take(items, @max_items)
  end

  defp candidates(_field, %DateTime{} = value, operators, timezone) do
    with true <- "on" in operators,
         {:ok, local} <- DateTime.shift_zone(value, timezone) do
      [%Choice{kind: :only, operator: "on", value: Date.to_iso8601(DateTime.to_date(local))}]
    else
      _ -> []
    end
  end

  defp candidates(_field, value, operators, _timezone) do
    case {"equals" in operators, text(value)} do
      {true, text} when is_binary(text) and text != "" ->
        [
          %Choice{kind: :only, operator: "equals", value: text},
          %Choice{kind: :out, operator: "not_equals", value: text}
        ]

      _ ->
        []
    end
  end

  # A map's first keys, as its cell lists them, each holding a short value
  # a person could have typed, and the keys of a small map one level below,
  # as an audit row's `"price" => %{"from" => .., "to" => ..}`. A value the
  # audit redacted is no value of the field's.
  defp pairs(map) do
    map
    |> sorted_entries()
    |> Enum.flat_map(fn
      {key, value} when is_non_struct_map(value) and map_size(value) <= 3 ->
        for {inner, v} <- sorted_entries(value), choice = pair([key, inner], v), do: choice

      {key, value} ->
        List.wrap(pair([key], value))
    end)
    |> Enum.take(@max_pairs)
  end

  defp pair(path, value) do
    text = pair_text(value)

    if is_binary(text) and text != "" and String.length(text) <= @max_pair_value and
         not StoredMap.redacted?(value),
       do: %Choice{kind: :pair, operator: "equals", value: text, path: path, shown: value}
  end

  defp sorted_entries(map) do
    map
    |> Enum.flat_map(fn
      {key, value} when is_binary(key) -> [{key, value}]
      {key, value} when is_atom(key) -> [{Atom.to_string(key), value}]
      _other -> []
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp pair_text(value) when is_binary(value), do: value
  defp pair_text(value) when is_boolean(value), do: to_string(value)
  defp pair_text(value) when is_number(value), do: to_string(value)
  defp pair_text(_value), do: nil

  # A value as a filter row holds one: as the filter form would have it typed
  # or picked.
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_boolean(value), do: to_string(value)
  defp text(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp text(%Date{} = value), do: Date.to_iso8601(value)
  defp text(%Ash.CiString{} = value), do: to_string(value)

  defp text(%{__struct__: Money, currency: currency, amount: %Decimal{} = amount}),
    do: "#{currency} #{Decimal.to_string(amount, :normal)}"

  defp text(_value), do: nil

  # Only a row the filter reads as the menu means it: one its field's type
  # casts, so the chip it makes reads the value as the cell did.
  defp readable?(%Choice{} = choice, %FilterField{field: field} = filter_field, timezone) do
    row = row(choice, filter_field)

    CustomFilter.readable?(row) and CustomFilter.fits?(row, filter_field) and
      match?(
        {:ok, _},
        CustomFilter.cast_row_value(field, choice.operator, choice.value, timezone)
      )
  end

  @doc "The filter row `choice` adds, on `filter_field`."
  def row(%Choice{} = choice, %FilterField{} = filter_field) do
    %CustomFilter{
      uuid: Ash.UUID.generate(),
      field_name: filter_field.name,
      operator: choice.operator,
      value: choice.value,
      path: if(CustomFilter.map_field?(filter_field), do: choice.path || [])
    }
  end

  @doc """
  What a menu entry reads as. An item or a map's value reads as `shown`
  renders, so the entry is given the parts: its words and its value.
  """
  def label(%Choice{kind: :only, operator: "is_nil"}), do: gettext("Filter by empty")
  def label(%Choice{kind: :out, operator: "is_not_nil"}), do: gettext("Filter out empty")
  def label(%Choice{kind: :only, operator: "on"}), do: gettext("Filter by this day")
  def label(%Choice{kind: :only}), do: gettext("Filter by this value")
  def label(%Choice{kind: :out}), do: gettext("Filter out this value")
  def label(%Choice{kind: :item}), do: gettext("Has")

  def label(%Choice{kind: :pair, path: path}),
    do: gettext("%{key} is", key: Enum.join(path, " › "))

  @doc "A map's value as its entry shows it, cut short."
  def shown_text(value) do
    text = pair_text(value) || ""

    if String.length(text) > @label_length,
      do: String.slice(text, 0, @label_length - 1) <> "…",
      else: text
  end
end
