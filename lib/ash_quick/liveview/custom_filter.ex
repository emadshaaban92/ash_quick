defmodule AshQuick.LiveView.CustomFilter do
  @moduledoc false
  @derive {JSON.Encoder, except: [:uuid]}
  @enforce_keys [:uuid, :operator]
  defstruct [:uuid, :operator, :field_name, :value, :children]

  alias AshQuick.LiveView.EnumOptions
  alias AshQuick.LiveView.FilterField
  alias AshQuick.LiveView.LocalDatetime
  alias AshQuick.LiveView.Utils

  require Ash.Expr
  import Ash.Expr, only: [expr: 1, ref: 1]

  # The operators that compare a field with no value.
  @valueless ~w(is_nil is_not_nil)

  # Every operator `FilterForm` offers a row, and so the only ones a row is
  # read by: a link can name any, and Ash's filter input reads the name as an
  # operator, a field, or a relationship to filter through.
  @operators ~w(equals not_equals gt gte lt lte contains not_contains starts_with ends_with
                in has_any on) ++ @valueless

  # And the ones a group joins its rows by.
  @group_operators ~w(and or)

  # The operators a `Money` row compares by, its amount in its currency.
  @money_operators ~w(equals not_equals gt gte lt lte)

  # AshMoney's type, named rather than referenced: AshQuick does not depend on
  # `ash_money`, so a host without it has no such module, and no field of it.
  @money_type AshMoney.Types.Money

  @string_types [Ash.Type.String, Ash.Type.CiString]

  @offered_types [
    Ash.Type.UUID,
    Ash.Type.UUIDv7,
    Ash.Type.Atom,
    Ash.Type.Boolean,
    Ash.Type.String,
    Ash.Type.CiString,
    Ash.Type.Date,
    Ash.Type.Integer,
    Ash.Type.Decimal,
    Ash.Type.DateTime,
    Ash.Type.UtcDatetimeUsec,
    Ash.Type.UtcDatetime,
    Ash.Type.Float
  ]

  @doc """
  Adds a row, or a group holding one row, under the group `uuid` names.

  `leaf` is the row's starting `field_name` and `operator`: the form's first
  offered field, since no field is one every resource offers.
  """
  def add_filter(filter, uuid, nested, leaf)

  def add_filter(%__MODULE__{uuid: uuid, children: children} = filter, uuid, "true", leaf)
      when is_list(children) do
    new_uuid = Ash.UUID.generate()

    %__MODULE__{
      filter
      | children:
          children ++
            [
              %__MODULE__{
                uuid: new_uuid,
                operator: "and",
                children: []
              }
            ]
    }
    |> add_filter(new_uuid, "false", leaf)
  end

  def add_filter(%__MODULE__{uuid: uuid, children: children} = filter, uuid, "false", leaf)
      when is_list(children) do
    %__MODULE__{filter | children: children ++ [new_leaf(leaf)]}
  end

  def add_filter(%__MODULE__{children: children} = filter, uuid, nested, leaf)
      when is_list(children) do
    %__MODULE__{filter | children: Enum.map(children, &add_filter(&1, uuid, nested, leaf))}
  end

  def add_filter(%__MODULE__{} = filter, _uuid, _nested, _leaf) do
    filter
  end

  @doc "A row comparing `leaf`'s field by its operator, with no value yet."
  def new_leaf(%{field_name: field_name, operator: operator}) do
    %__MODULE__{uuid: Ash.UUID.generate(), field_name: field_name, operator: operator, value: ""}
  end

  @doc "The node `uuid` names anywhere in `filter`'s tree, or `nil`."
  def find(%__MODULE__{uuid: uuid} = filter, uuid), do: filter

  def find(%__MODULE__{children: children}, uuid) when is_list(children),
    do: Enum.find_value(children, &find(&1, uuid))

  def find(%__MODULE__{}, _uuid), do: nil

  def update_filter(%__MODULE__{uuid: uuid} = filter, uuid, key, value) do
    Map.put(filter, key, value)
  end

  def update_filter(%__MODULE__{children: children} = filter, uuid, key, value)
      when is_list(children) do
    %__MODULE__{filter | children: Enum.map(children, &update_filter(&1, uuid, key, value))}
  end

  def update_filter(%__MODULE__{} = filter, _uuid, _key, _value) do
    filter
  end

  def remove_filter(%__MODULE__{children: children} = filter, uuid) when is_list(children) do
    %__MODULE__{
      filter
      | children:
          children |> Enum.reject(&(&1.uuid == uuid)) |> Enum.map(&remove_filter(&1, uuid))
    }
  end

  def remove_filter(%__MODULE__{} = filter, _uuid) do
    filter
  end

  @doc """
  `filter` without the rows that name one of `field_names`, anywhere in its
  tree, or `nil` when `filter` is itself such a row.
  """
  def reject_fields(filter, field_names), do: reject_rows(filter, &(&1.field_name in field_names))

  @doc """
  `filter` without the rows `reject?` answers true for, anywhere in its tree,
  or `nil` when `filter` is itself such a row, or is `nil`.
  """
  def reject_rows(nil, _reject?), do: nil

  def reject_rows(%__MODULE__{children: [_ | _] = children} = filter, reject?) do
    children =
      children
      |> Enum.map(&reject_rows(&1, reject?))
      |> Enum.reject(&is_nil/1)

    %__MODULE__{filter | children: children}
  end

  def reject_rows(%__MODULE__{} = filter, reject?),
    do: if(reject?.(filter), do: nil, else: filter)

  @doc """
  `filter` without the node `uuid` names, or `nil` when what is left filters by
  nothing: the list then reads as it would with no filter, and so does its URL.
  """
  def without(%__MODULE__{uuid: uuid}, uuid), do: nil

  def without(%__MODULE__{} = filter, uuid) do
    filter = remove_filter(filter, uuid)
    if applied?(filter), do: filter
  end

  @doc """
  Whether `filter` filters by anything: a row with a field and a value, or
  with an operator that takes none, as Is Empty, or a group holding one. A row
  left without a value is skipped by `build_ash_filter/2`, and so is a group
  of only such rows.
  """
  def applied?(%__MODULE__{children: [_ | _] = children}), do: Enum.any?(children, &applied?/1)

  def applied?(%__MODULE__{field_name: field_name, operator: operator, value: value}),
    do:
      is_binary(field_name) and is_binary(operator) and
        (operator in @valueless or has_value?(value))

  defp has_value?(value) when is_list(value), do: Enum.any?(value, &has_value?/1)
  defp has_value?(value), do: value not in [nil, ""]

  @doc """
  What a row's value is, by its operator: `:none` for Is Empty and Is Not
  Empty, which compare with nothing; `:list` for Any Of and Has Any Of;
  `:day` for On Day, a date naming a whole day of a timestamp; and `:scalar`
  for the rest.
  """
  def value_shape(operator) when operator in @valueless, do: :none
  def value_shape(operator) when operator in ~w(in has_any), do: :list
  def value_shape("on"), do: :day
  def value_shape(_operator), do: :scalar

  @doc """
  The value a row keeps when its operator changes from `from` to `to`: as it
  was when both take the same kind of value, one value in or out of a list,
  and nothing otherwise, since a date is no instant and neither is anything
  Is Empty compares with.
  """
  def reshape_value(value, from, to) do
    case {value_shape(from), value_shape(to)} do
      {same, same} -> value
      {:scalar, :list} -> if has_value?(value), do: [value], else: []
      {:list, :scalar} -> value |> List.wrap() |> Enum.find("", &has_value?/1)
      {_, :list} -> []
      _ -> ""
    end
  end

  @doc """
  The nodes the list shows as one chip each: the root's own rows and groups
  that filter by something, or the root itself when a link made it a row.
  """
  def chips(%__MODULE__{children: children}) when is_list(children),
    do: Enum.filter(children, &applied?/1)

  def chips(%__MODULE__{} = filter), do: if(applied?(filter), do: [filter], else: [])

  @doc "The rows of `filter`'s tree that filter by something, in order."
  def applied_leaves(%__MODULE__{} = filter),
    do: filter |> leaves() |> Enum.filter(&applied?/1)

  @doc """
  The fields of `resource` the filter form offers, before field policies narrow
  them, as `FilterField`s: public, `filterable?` attributes, aggregates and
  calculations of a type it has a row for, but no belongs_to relationship's
  source attribute, no `sensitive?` field, no field filterable by simple
  equality only, and no calculation without an expression.

  With `names`, a list's `filterable:`, those it names, in its order: each a
  field of `resource`, or `{relationship, field}`, a field reached through a
  public belongs_to relationship that has a read to read its destination
  with, one the filter offers on that destination, or `:defaults`, which
  stands for the fields offered unsaid, in their order, always: a field
  named `defaults` is offered only through it. A field is offered
  once, where it is first named. Any other name is left out, so a caller
  that refuses one checks it with `filterable_field?/2`. Unsaid, only
  `resource`'s own fields are offered.
  """
  def filterable_fields(resource, names \\ nil)

  def filterable_fields(resource, nil),
    do: resource |> own_fields() |> Enum.map(&FilterField.own(resource, &1))

  def filterable_fields(resource, names) do
    own = own_fields(resource)
    by_name = Map.new(own, &{&1.name, &1})

    names = names |> Enum.flat_map(&expand_defaults(&1, own)) |> Enum.uniq()

    for name <- names, field = filterable_field(resource, name, by_name), do: field
  end

  # `:defaults` stands for the fields offered unsaid, in their order, read
  # off the resource as it is now, so a field it gains is offered too. A field
  # named before the marker keeps its place and is not offered again.
  defp expand_defaults(:defaults, own), do: Enum.map(own, & &1.name)
  defp expand_defaults(name, _own), do: [name]

  defp filterable_field(resource, name, by_name) when is_atom(name) do
    if field = by_name[name], do: FilterField.own(resource, field)
  end

  defp filterable_field(resource, {relationship, name}, _by_name)
       when is_atom(relationship) and is_atom(name) do
    with %{} = relationship <- filterable_relationship(resource, relationship),
         %{} = field <-
           relationship.destination |> own_fields() |> Enum.find(&(&1.name == name)) do
      FilterField.through(relationship, field)
    end
  end

  defp filterable_field(_resource, _name, _by_name), do: nil

  # One hop through a belongs_to, and only one: a row compares a product with
  # the one brand it has. A to-many relationship would ask whether any of its
  # records match, which is another question, and a longer path joins a table
  # for each hop. Ash reads the brand with the relationship's read, so one
  # with none to read it with could never answer a row.
  defp filterable_relationship(resource, name) do
    case Ash.Resource.Info.public_relationship(resource, name) do
      %Ash.Resource.Relationships.BelongsTo{} = relationship ->
        if Map.get(relationship, :filterable?, true) and destination_read(relationship),
          do: relationship

      _ ->
        nil
    end
  end

  defp own_fields(resource) do
    belongs_to_source_attributes =
      resource
      |> Ash.Resource.Info.relationships()
      |> Enum.filter(&(&1.type == :belongs_to))
      |> Enum.map(& &1.source_attribute)

    resource
    |> Ash.Resource.Info.fields([:attributes, :aggregates, :calculations])
    # A `sensitive?` field shows as a mask on every page, and a filter on it
    # would give the value back: rows that start with "4", then "43", and so
    # on, a character at a time, with only the list to read the answer off.
    |> Enum.reject(
      &(&1.name in belongs_to_source_attributes or AshQuick.Info.sensitive?(resource, &1.name))
    )
    |> Enum.filter(&(&1.public? and filterable?(&1) and offered_type?(&1)))
  end

  # `filterable? :simple_equality` lets Ash compare a field only once in a
  # filter, by `==`, outside any `or` or `not`, and a row of the form can sit
  # in an Any group, beside another on the same field, or under Is Not
  # Empty's `not`: Ash would refuse the read. Such a field is left out.
  #
  # A calculation is asked in the filter by its expression, so one computed
  # in Elixir only, with `calculate/3` and no `expression/2`, cannot be: the
  # read raises on a data layer that filters in SQL, as AshPostgres does.
  # Sorting asks the same of a calculation, `Ash.Resource.Info.sortable?/3`.
  defp filterable?(%{filterable?: filterable?}) when filterable? != true, do: false

  defp filterable?(%Ash.Resource.Calculation{calculation: {module, _opts}}),
    do:
      match?({:module, _}, Code.ensure_compiled(module)) and
        function_exported?(module, :expression, 2)

  defp filterable?(%Ash.Resource.Calculation{}), do: false
  defp filterable?(_field), do: true

  @doc """
  The fields of `resource` the filter form offers the visitor `scope` names,
  in its order: `filterable_fields/2`, less any field a field policy hides
  from them on every record of `action`'s read. Ash would read such a field
  as `nil` in the filter, so the list would come back empty and look like an
  answer. A field hidden on some records only stays. A field reached through
  a relationship is asked of its destination's read.

  Without `action`, the fields are not narrowed.
  """
  def offered_fields(resource, names, nil, _scope), do: filterable_fields(resource, names)

  def offered_fields(resource, names, action, scope),
    do: resource |> filterable_fields(names) |> visible(action, scope)

  @doc """
  Those of `fields`, `FilterField`s, the visitor `scope` names may see: on
  every record, or with `filter_is: false` in `opts`, on every record they
  read. A field of the list's resource is asked of `action`, the list's read;
  one reached through a relationship of the read the relationship reads its
  destination with: its `read_action`, or the destination's primary read,
  which `filterable_fields/2` offers none without. With `action` given as
  `nil`, the list's own fields are not narrowed.

  A related field is asked as the filter reads it, through the relationship:
  with `accessing_from` naming it in the context, so a policy written with
  `accessing_from/2` holds as it does for the column. Every field of a
  destination the visitor may not read through the relationship at all is
  left out, since a row on one could never match; a read policy that only
  filters the destination leaves its fields offered.
  """
  def visible(fields, action, scope, opts \\ []) do
    visible =
      for {relationship, group} <- Enum.group_by(fields, & &1.relationship),
          {resource, read} = read_by(relationship, group, action),
          opts = through(relationship, opts),
          readable?(relationship, resource, read, scope, opts),
          by_name = Map.new(group, &{&1.field.name, &1}),
          name <- visible_names(Map.keys(by_name), resource, read, scope, opts),
          into: MapSet.new(),
          do: by_name[name].name

    Enum.filter(fields, &MapSet.member?(visible, &1.name))
  end

  defp visible_names(names, _resource, nil, _scope, _opts), do: names

  defp visible_names(names, resource, read, scope, opts),
    do: Utils.visible_fields(names, resource, read, scope, opts)

  # The context Ash reads a related field's policies in, inside the `exists`
  # a path row is built as: one naming the relationship it was reached
  # through.
  defp through(nil, opts), do: opts

  defp through(relationship, opts) do
    accessing_from = %{accessing_from: %{source: relationship.source, name: relationship.name}}
    Keyword.update(opts, :context, accessing_from, &Map.merge(&1, accessing_from))
  end

  # Only a definite refusal hides a destination: a read policy refuses a read
  # by filtering it to nothing, which `Ash.can/3` answers as allowed, so it is
  # the filter it would read with that is asked. Run without queries, a
  # policy that filters by the record stays a filter, and its fields offered.
  defp readable?(nil, _resource, _read, _scope, _opts), do: true
  defp readable?(_relationship, _resource, nil, _scope, _opts), do: true

  defp readable?(_relationship, resource, read, scope, opts) do
    case Ash.can({resource, read.name}, scope,
           context: opts[:context],
           alter_source?: true,
           run_queries?: false
         ) do
      {:ok, false} -> false
      {:ok, false, _error} -> false
      {:ok, true, %{filter: %Ash.Filter{expression: false}}} -> false
      _readable_or_error -> true
    end
  end

  defp read_by(nil, [field | _], action), do: {field.resource, action}

  defp read_by(relationship, _fields, _action),
    do: {relationship.destination, destination_read(relationship)}

  defp destination_read(%{read_action: nil, destination: destination}),
    do: Ash.Resource.Info.primary_action(destination, :read)

  defp destination_read(%{read_action: name, destination: destination}),
    do: Ash.Resource.Info.action(destination, name, :read)

  @doc """
  Whether the filter form offers `name`, as `filterable:` names it, on
  `resource`.
  """
  def filterable_field?(resource, name), do: filterable_fields(resource, [name]) != []

  # A field with a fixed set of values is offered whatever its type: an
  # `Ash.Type.Enum` is a module of its own, so no list of types could name it.
  # So is a list of such values, which Has Any Of asks about. An atom without
  # `one_of` is offered too, and typed in.
  defp offered_type?(field),
    do:
      EnumOptions.kind(field) in [:single, :array] or field.type in @offered_types or
        money?(field)

  @doc """
  Whether `field` holds a `Money`, as AshMoney's type stores it by default: as
  a currency and an amount the data layer can read apart, the composite
  `money_with_currency` on AshPostgres. Each row compares the two, as
  `build_ash_filter/2` writes it. One stored as a map, `storage_type: :map`,
  is not offered: its amount is no number the data layer can compare.
  """
  def money?(%{type: type} = field) do
    constraints = Map.get(field, :constraints) || []

    base_type(type) == @money_type and Ash.Type.composite?(type, constraints)
  end

  def money?(_field), do: false

  defp base_type({:array, _type}), do: nil

  defp base_type(type) do
    type = Ash.Type.get_type(type)

    if Ash.Type.NewType.new_type?(type),
      do: base_type(Ash.Type.NewType.subtype_of(type)),
      else: type
  end

  @doc """
  The fields a row can name on `resource`, as `FilterField`s, by the name a
  row holds them under: every attribute, aggregate and calculation of its
  own, and those of `names`, a list's offered fields as `filterable:` names
  them, reached through a relationship.
  """
  def fields_by_name(resource, names \\ nil) do
    own =
      resource
      |> Ash.Resource.Info.fields([:attributes, :aggregates, :calculations])
      |> Enum.map(&FilterField.own(resource, &1))

    paths =
      names
      |> List.wrap()
      |> Enum.filter(&is_tuple/1)
      |> then(&filterable_fields(resource, &1))

    Map.new(own ++ paths, &{&1.name, &1})
  end

  @doc """
  `value` cast by `field`'s type, as Ash casts a filter's values: with
  `Ash.Type.coerce/3`, which differs from `cast_input/3` for some types, an
  atom among them, which `cast_input/3` accepts only when the VM already
  knows it.

  A link can pair any field with any value, and some types raise on one they
  were never meant to see, as a list type handed a string reaches
  `Enumerable`. Only such errors read as the value being invalid; anything
  else a type raises is a bug and is left to surface.
  """
  def cast_value(field, value) do
    Ash.Type.coerce(field.type, value, Map.get(field, :constraints) || [])
  rescue
    _ in [ArgumentError, FunctionClauseError, Protocol.UndefinedError] -> {:error, "is invalid"}
  end

  @doc """
  A row's value cast as its operator reads it: nothing for Is Empty, each
  value of Any Of by `field`'s type, each of Has Any Of by the type of an
  item of `field`'s list, a date for On Day, and the value by `field`'s type
  otherwise. The first value of a list that will not cast is the error.

  On Day's date is read as `build_ash_filter/2` reads it, by
  `LocalDatetime.day_range/3`: an ISO 8601 date, and a day in `timezone`,
  which a zone the time zone database cannot load has none of. The row says
  so, rather than the read refusing the whole filter.
  """
  def cast_row_value(field, operator, value, timezone \\ AshQuick.Config.timezone()) do
    case value_shape(operator) do
      :none ->
        {:ok, nil}

      :day ->
        case LocalDatetime.day_range(value, timezone) do
          {:ok, _from, _to} -> Date.from_iso8601(value)
          :error -> {:error, "is invalid"}
        end

      :list ->
        item = if operator == "has_any", do: item_field(field), else: field
        value |> List.wrap() |> Enum.filter(&has_value?/1) |> cast_values(item, [])

      :scalar ->
        cast_value(field, value)
    end
  end

  # One item of a list field, by its type and the constraints its items have.
  # Any other field is its own item: Has Any Of on one, which only a link
  # carries, is dropped before the read (`ListUtils`), with the
  # refused-filter flash.
  defp item_field(%{type: {:array, type}} = field),
    do: %{type: type, constraints: (Map.get(field, :constraints) || [])[:items] || []}

  defp item_field(field), do: field

  defp cast_values([], _field, cast), do: {:ok, Enum.reverse(cast)}

  defp cast_values([value | rest], field, cast) do
    case cast_value(field, value) do
      {:ok, value} -> cast_values(rest, field, [value | cast])
      error -> error
    end
  end

  @doc """
  `filter` with each row comparing a `Money`, among `fields`, holding its
  value with its currency, `USD 10` for `10`: a bare amount is in the field's
  default currency, or with none, the one ex_money reads from Localize's
  locale, which a host may set per reader, USD for one and EGP for another.
  Held with its currency, the row reads the same for everyone its link
  reaches, and its chip says which. A value that will not cast is left as
  typed.
  """
  def with_currencies(filter, fields) do
    money =
      for %FilterField{name: name, field: field} <- fields,
          money?(field),
          into: %{},
          do: {name, field}

    filter
    |> applied_leaves()
    |> Enum.reduce(filter, fn %__MODULE__{
                                uuid: uuid,
                                field_name: name,
                                operator: operator,
                                value: value
                              },
                              filter ->
      with %{} = field <- money[name],
           true <- operator in @money_operators,
           {:ok, %{currency: currency, amount: amount}} <- cast_value(field, value) do
        update_filter(filter, uuid, :value, "#{currency} #{Decimal.to_string(amount, :normal)}")
      else
        _ -> filter
      end
    end)
  end

  @doc """
  The filter Ash reads `filter` as, or `nil` when it filters by nothing.

  Only what `FilterForm` could have written is read: a group joining its
  rows by `"and"` or `"or"`, and a row comparing a field by an operator the
  form offers with one value or a list of them. A link can carry any JSON,
  and Ash's filter input reads a name where an operator goes as an
  operator, a field or a relationship to filter through, so anything else
  filters by nothing.

  Options:

    * `:timezone` — the zone On Day reads its date in, as the instants from
      that day's first moment up to the next day's: the zone the list shows
      timestamps in, `AshQuick.Scope.timezone/1`, which the list passes;
      `AshQuick.Config.timezone/0` when none is given.
    * `:fields` — the fields a row can name, by name, as `fields_by_name/2`
      gives them, and the only ones: a row naming any other filters by
      nothing. Unsaid, a row can name any field. Is Empty on a string also
      keeps one holding `""`, and on a list one holding `[]`, which read as
      empty in the list, and only a field's type says which it is.
  """
  def build_ash_filter(filter, opts \\ []) do
    timezone = Keyword.get_lazy(opts, :timezone, &AshQuick.Config.timezone/0)
    build(filter, timezone, Keyword.get(opts, :fields, :any))
  end

  defp build(%__MODULE__{operator: operator, children: children}, timezone, fields)
       when is_list(children) and children != [] and operator in @group_operators do
    case Enum.map(children, &build(&1, timezone, fields)) |> Enum.reject(&is_nil/1) do
      [] -> nil
      filters -> %{operator => filters}
    end
  end

  defp build(%__MODULE__{children: [_ | _]}, _timezone, _fields), do: nil

  # Only an operator the form offers is read, on a field the list offers, as
  # `:fields` names them, with a value that is one value or a list of them.
  defp build(%__MODULE__{} = row, timezone, fields) do
    if readable_row?(row, fields),
      do: build_row(row, timezone, if(fields == :any, do: %{}, else: fields))
  end

  defp readable_row?(%__MODULE__{field_name: name} = row, fields),
    do: is_binary(name) and readable?(row) and (fields == :any or Map.has_key?(fields, name))

  @doc """
  Whether `row` compares by an operator `FilterForm` offers, with a value
  that operator can take: none, one value, or for Any Of and Has Any Of a
  list of them. `build_ash_filter/2` reads no other row.
  """
  def readable?(%__MODULE__{operator: operator, value: value}) when operator in @operators do
    case value_shape(operator) do
      :none -> true
      :list -> value?(value)
      _shape -> not is_list(value) and value?(value)
    end
  end

  def readable?(%__MODULE__{}), do: false

  @doc false
  # The operators a row is read by, and the types a field is offered by, for
  # the test holding them to what `FilterForm` offers.
  def operators, do: @operators
  def offered_types, do: @offered_types

  # One value as JSON writes one, a list of them, or none. A link's list can
  # hold blanks and empty lists beside its values, which hold nothing.
  defp value?(values) when is_list(values), do: Enum.all?(values, &(&1 == [] or one_value?(&1)))
  defp value?(value), do: one_value?(value)

  defp one_value?(value), do: is_nil(value) or scalar?(value)

  defp scalar?(value), do: is_binary(value) or is_number(value) or is_boolean(value)

  # Is Empty on a field through a relationship asks that no related record
  # holds a value: a row with no owner has an empty owner's name, as one
  # whose owner the reader may not read does, which its column shows blank.
  defp build_row(%__MODULE__{field_name: field_name, operator: operator}, _timezone, fields)
       when is_binary(field_name) and operator in @valueless do
    empty = fields[field_name] && empty_value(fields[field_name].field.type)

    case {FilterField.path?(field_name), operator} do
      {true, "is_nil"} -> %{"not" => on(field_name, &filled(&1, empty))}
      {false, "is_nil"} -> on(field_name, &blank(&1, empty))
      {_path?, "is_not_nil"} -> on(field_name, &filled(&1, empty))
    end
  end

  # A link can hand Any Of one value rather than a list.
  defp build_row(
         %__MODULE__{field_name: field_name, operator: "in", value: value},
         _timezone,
         _fields
       )
       when is_binary(field_name) do
    case value |> List.wrap() |> Enum.filter(&has_value?/1) do
      [] -> nil
      values -> at(field_name, %{"in" => values})
    end
  end

  # On Day filters by a day only when it can read one: a date that will not
  # parse, or a zone that will not load, filters by nothing, as a row without
  # a value does. The form refuses either under the row, with
  # `cast_row_value/4`, and the list drops a link's before the read, with the
  # refused-filter flash, so neither is applied as something else: compared
  # as written, a timestamp would cast a bare date as its midnight UTC, and a
  # datetime string as that instant.
  defp build_row(
         %__MODULE__{field_name: field_name, operator: "on", value: value},
         timezone,
         _fields
       )
       when is_binary(field_name) do
    case LocalDatetime.day_range(value, timezone) do
      {:ok, from, to} -> at(field_name, %{"gte" => from, "lt" => to})
      :error -> nil
    end
  end

  # Has Any Of keeps a row whose list holds any value picked. Ash's
  # `intersects/2`, which AshPostgres reads as `&&`, rather than its
  # `overlaps` operator, which a filter's input cannot name.
  defp build_row(
         %__MODULE__{field_name: field_name, operator: "has_any", value: value},
         _timezone,
         _fields
       )
       when is_binary(field_name) do
    case value |> List.wrap() |> Enum.filter(&has_value?/1) do
      [] -> nil
      values -> at(field_name, %{"intersects" => values})
    end
  end

  defp build_row(
         %__MODULE__{field_name: field_name, operator: "not_contains", value: value},
         _timezone,
         _fields
       )
       when is_binary(field_name) and is_binary(value) and value != "" do
    on(field_name, &%{"not" => %{&1 => %{"contains" => value}}})
  end

  defp build_row(
         %__MODULE__{field_name: field_name, operator: operator, value: value},
         _timezone,
         _fields
       )
       when is_binary(field_name) and operator in ["starts_with", "ends_with"] and
              is_binary(value) and value != "" do
    # Ash's own predicates rather than `like`, which only AshPostgres defines
    # and which would read a `%` or `_` in the value as a wildcard.
    at(field_name, %{"string_#{operator}" => value})
  end

  # A `Money` compares by its amount, and only with one in the same currency:
  # AshMoney's own comparison of two in different currencies raises, on
  # Postgres for any row the list holds in another, so it is never asked.
  # `EUR 10` is a `Money` in euros. The form holds each row with its
  # currency, `with_currencies/2`; a bare `10`, which only a link typed by
  # hand carries, is cast as its form input casts it: in the field's default
  # currency, or with none, that of Localize's locale. A value that will not
  # cast is compared as written, and the read refuses it, with the
  # refused-filter flash, as it does any value its field's type cannot cast.
  defp build_row(
         %__MODULE__{field_name: field_name, operator: operator, value: value},
         _timezone,
         fields
       )
       when is_binary(field_name) and operator in @money_operators and not is_nil(value) and
              value != "" and not is_list(value) do
    with %FilterField{field: field} <- fields[field_name],
         true <- money?(field),
         {:ok, %{currency: currency, amount: amount}} <- cast_value(field, value) do
      on(field_name, fn _name -> money(field.name, operator, to_string(currency), amount) end)
    else
      _ -> at(field_name, %{operator => value})
    end
  end

  defp build_row(
         %__MODULE__{field_name: field_name, operator: operator, value: value},
         _timezone,
         _fields
       )
       when is_binary(field_name) and is_binary(operator) and not is_nil(value) and value != "" do
    at(field_name, %{operator => value})
  end

  defp build_row(%__MODULE__{}, _timezone, _fields), do: nil

  defp at(field_name, predicate), do: on(field_name, &%{&1 => predicate})

  # The statement `statement` makes of a row's field, as Ash's filter input
  # reads it. A field through a relationship, `"brand.name"`, is asked inside
  # `exists(brand, ...)`, rather than as the nested `%{"brand" => %{"name" =>
  # ...}}`: Ash applies the brand's read policies inside an `exists`, so a row
  # is never kept for a brand its reader may not read, while a nested
  # reference makes the whole branch of the filter holding it demand a
  # readable brand, which drops a row with none even from an `or` beside it.
  # A relationship name the VM does not know is no relationship of the
  # resource, and is left to the read, which refuses it.
  defp on(field_name, statement) do
    case String.split(field_name, ".", parts: 2) do
      [name] ->
        statement.(name)

      [relationship, name] ->
        case FilterField.known_atom(relationship) do
          relationship when is_atom(relationship) ->
            Ash.Query.Exists.new([relationship], statement.(name))

          relationship ->
            %{relationship => statement.(name)}
        end
    end
  end

  # A `Money` field's amount compared with `amount`, on a row holding one in
  # `currency`. The currency is read as a string: the data layer holds a code,
  # and Ash, reading a `Money` itself, the atom it names. Not Equal keeps a
  # row in another currency, whose amount is not the one named.
  defp money(name, "not_equals", currency, amount),
    do: expr(not (^money(name, "equals", currency, amount)))

  defp money(name, operator, currency, amount) do
    expr(
      type(get_path(^ref(name), [:currency]), :string) == ^currency and
        ^amount(expr(get_path(^ref(name), [:amount])), operator, amount)
    )
  end

  defp amount(held, "equals", amount), do: expr(^held == ^amount)
  defp amount(held, "gt", amount), do: expr(^held > ^amount)
  defp amount(held, "gte", amount), do: expr(^held >= ^amount)
  defp amount(held, "lt", amount), do: expr(^held < ^amount)
  defp amount(held, "lte", amount), do: expr(^held <= ^amount)

  # Whether a field has no value: `nil`, or the empty value its type also
  # reads as empty with, when it has one.
  defp blank(name, nil), do: %{name => %{"is_nil" => true}}

  defp blank(name, empty),
    do: %{"or" => [%{name => %{"is_nil" => true}}, %{name => %{"eq" => empty}}]}

  defp filled(name, nil), do: %{name => %{"is_nil" => false}}

  defp filled(name, empty),
    do: %{"and" => [%{name => %{"is_nil" => false}}, %{name => %{"not_eq" => empty}}]}

  # The value besides `nil` a field reads as empty with: `""` for a string,
  # or a type built on one, as `AshQuick.AshTypes.Text` is, and `[]` for a
  # list. `nil` for any other.
  defp empty_value({:array, _type}), do: []

  defp empty_value(type) do
    type = Ash.Type.get_type(type)

    cond do
      type in @string_types -> ""
      Ash.Type.NewType.new_type?(type) -> empty_value(Ash.Type.NewType.subtype_of(type))
      true -> nil
    end
  end

  @doc """
  A row's value as written: a link's can be any JSON, and a list, as Any Of
  takes, reads as its values joined by commas rather than as iodata, which
  raises for most lists.
  """
  def as_written(value) when is_binary(value), do: value
  def as_written(value) when is_list(value), do: Enum.map_join(value, ", ", &as_written/1)
  def as_written(value) when is_number(value) or is_atom(value), do: to_string(value)
  def as_written(value), do: inspect(value)

  @doc """
  The field names `filter` names anywhere in its tree, once each, without the
  values it compares them with.
  """
  def field_names(%__MODULE__{} = filter),
    do:
      filter |> leaves() |> Enum.map(& &1.field_name) |> Enum.filter(&is_binary/1) |> Enum.uniq()

  @doc """
  The values `filter` compares its fields with, anywhere in its tree, as the
  strings they were typed as, each of a list's on its own.
  """
  def values(%__MODULE__{} = filter) do
    for %{value: value} <- leaves(filter),
        value <- List.wrap(value),
        is_binary(value) or is_number(value),
        value = to_string(value),
        value != "",
        uniq: true,
        do: value
  end

  @doc """
  Whether the form shows `node` as a group: one holding nodes, or one whose
  rows were all removed. A node naming a field with `children: []`, as a link
  can write one, is a row, as `leaves/1` and `build_ash_filter/2` read it.
  """
  def group?(%__MODULE__{children: [_ | _]}), do: true
  def group?(%__MODULE__{children: [], field_name: nil}), do: true
  def group?(%__MODULE__{}), do: false

  @doc """
  The rows of `filter`'s tree, in order. A node with children is a group, and
  one without is a row, `children: []` included, as `build_ash_filter/2` reads
  it.
  """
  def leaves(%__MODULE__{children: [_ | _] = children}),
    do: Enum.flat_map(children, &leaves/1)

  def leaves(%__MODULE__{} = leaf), do: [leaf]

  def to_string!(%__MODULE__{} = filter),
    do: filter |> JSON.encode!() |> :base64.encode()

  @doc """
  Decodes what `to_string!/1` wrote, or `nil` for anything else.

  The encoded form travels in the URL, so this is handed strings somebody
  truncated or invented, and base64 over JSON over field names is three layers
  to be wrong at. All three mean one thing to the caller: it has not been told
  what to filter by.

  Only those three are answered, so a bug in `from_map/1` still surfaces rather
  than becoming a silent unfiltered list. Which is why base64 is asked rather
  than rescued: `:base64.decode/1` has no error type to name — malformed input
  reaches at least four different exceptions — while `Base.decode64/1` answers
  `:error` for all of them, and still decodes the padding `to_string!/1` writes.
  """
  def from_string(filter_string) when is_binary(filter_string) do
    case Base.decode64(filter_string) do
      {:ok, json} -> json |> JSON.decode!() |> from_map() |> root()
      :error -> nil
    end
  rescue
    # `String.to_existing_atom/1` on a key naming no field of this struct.
    ArgumentError -> nil
    JSON.DecodeError -> nil
  end

  # The form draws its root as a group, and reads its rows from it, so a
  # root that is one row, as a link can write one, is that row in an And
  # group, which filters as the row does, and an empty root is a group with
  # no rows.
  defp root(nil), do: nil
  defp root(%__MODULE__{children: [_ | _]} = group), do: group

  defp root(%__MODULE__{field_name: nil, children: children} = empty)
       when children in [nil, []],
       do: %__MODULE__{empty | operator: "and", children: []}

  defp root(%__MODULE__{} = row),
    do: %__MODULE__{uuid: Ash.UUID.generate(), operator: "and", children: [row]}

  # A group joins its rows by `"and"` or `"or"`, the only ones the form
  # writes; any other name reads as no filter, as a group whose operator is
  # no string does.
  defp from_map(%{"children" => [_ | _] = children} = filter_map) do
    if filter_map["operator"] in @group_operators and well_formed?(filter_map),
      do: group(filter_map, children)
  end

  # Each slot holds what the form writes there, and nothing else reaches the
  # form or the read: text for the operator and field name, one value or a
  # list of them for the value, and a list for the children. Every slot is
  # JSON, so an object or a list could stand anywhere, and the form reads the
  # operator and field name as text.
  defp from_map(%{} = filter_map) do
    if well_formed?(filter_map), do: row(filter_map)
  end

  # Valid JSON that is not a filter — a bare list, a number, or one of those
  # nested under `"children"`. Answered here so that a `FunctionClauseError`
  # from this module stays distinguishable from a real bug.
  defp from_map(_), do: nil

  defp well_formed?(filter_map) do
    text?(filter_map["operator"]) and text?(filter_map["field_name"]) and
      value?(filter_map["value"]) and
      (is_nil(filter_map["children"]) or is_list(filter_map["children"]))
  end

  defp text?(value), do: is_nil(value) or is_binary(value)

  defp group(filter_map, children) do
    filter_map
    |> Map.put("uuid", Ash.UUID.generate())
    |> Map.put("children", children |> Enum.map(&from_map/1) |> Enum.reject(&is_nil/1))
    |> Enum.into(%{}, fn {key, val} -> {String.to_existing_atom(key), val} end)
    |> then(&struct(__MODULE__, &1))
  end

  defp row(filter_map) do
    filter_map
    |> Map.put("uuid", Ash.UUID.generate())
    |> Enum.into(%{}, fn {key, val} -> {String.to_existing_atom(key), val} end)
    |> then(&struct(__MODULE__, &1))
  end
end
