defmodule AshQuick.LiveView.MapFilter do
  @moduledoc false
  # A filter row on a map column: one whose type says only that it holds a
  # map, so its keys are known at runtime only, as an audit row's `changes`
  # are. The row names a key path inside the map, `["price", "to"]`, or none
  # to look at every value at any depth, and compares what it finds there.
  #
  # Asked of Postgres as an SQL/JSON path, `changes @? '$."price"."to" ? (@ >
  # 10)'`, so it is offered only on an AshPostgres resource, where a map is
  # stored as `jsonb`. Ash's portable `get_path` with a cast was the other
  # way, but a single row holding `"abc"` where the others hold numbers makes
  # Postgres raise on the cast, and the whole list fails with it. A path
  # compares each value by what it holds: one of another type than the value
  # typed just does not match, and the rest of the list reads as before.
  #
  # The path is built here as text and passed to the query as a bound
  # parameter, never spliced into the SQL. Every key and every string in it is
  # written as a quoted JSON string, so nothing typed can end a key or a
  # string early and add to the path.
  #
  # Lax mode, Postgres's default, reads through arrays: `$."items"."sku"`
  # finds the `sku` of each item of an `items` list, and a row matches when
  # any value found does.

  use Gettext, backend: AshQuick.Gettext

  require Ash.Expr
  import Ash.Expr, only: [expr: 1, ref: 1]

  # The operators a map row compares what it finds by, each with a value, in
  # the order the form offers them: what a person most often asks of a map
  # whose keys they half know is whether it mentions something.
  @operators ~w(contains not_contains equals not_equals starts_with ends_with gt gte lt lte)

  # And the ones asking whether a key is there at all, which need a key. A
  # key holding `null` is there.
  @key_operators ~w(has_key missing_key)

  @doc "The operators a map row compares a value by, in the form's order."
  def operators, do: @operators

  @doc "The operators a map row asks whether its key is there by."
  def key_operators, do: @key_operators

  @doc """
  Whether the filter offers `field` of `resource` as a map, with a key path:
  an attribute of `Ash.Type.Map`, or a type built on it, on an AshPostgres
  resource. A list of maps is stored as an array of `jsonb`, which a path
  does not read, and a calculation or aggregate typed as a map need not be
  `jsonb` at all, so neither is.
  """
  def offered?(resource, %Ash.Resource.Attribute{type: type}),
    do: map_type?(type) and Ash.DataLayer.data_layer(resource) == AshPostgres.DataLayer

  def offered?(_resource, _field), do: false

  @doc "Whether `type` is `Ash.Type.Map`, or a type built on it."
  def map_type?({:array, _type}), do: false

  def map_type?(type) do
    type = Ash.Type.get_type(type)

    cond do
      type == Ash.Type.Map ->
        true

      is_atom(type) and Ash.Type.NewType.new_type?(type) ->
        map_type?(Ash.Type.NewType.subtype_of(type))

      true ->
        false
    end
  end

  @doc """
  Whether `row`, a `CustomFilter` holding a key path, is one the form could
  have written: a path of keys, an operator a map row offers, and a value it
  can take. Asking whether a key is there needs a key.
  """
  def readable?(%{path: path, operator: operator, value: value}) when is_list(path) do
    Enum.all?(path, &key?/1) and
      cond do
        operator in @key_operators -> path != []
        operator in @operators -> scalar?(value)
        true -> false
      end
  end

  def readable?(_row), do: false

  # A key as the form can show and write it back: typed with dots, and
  # trimmed, so a key holding a dot, blank at either end or empty is one
  # editing the row would split or change. A link holding one is refused.
  defp key?(key),
    do:
      is_binary(key) and key != "" and key == String.trim(key) and
        not String.contains?(key, [".", <<0>>])

  defp scalar?(value),
    do: is_nil(value) or is_binary(value) or is_number(value) or is_boolean(value)

  @doc """
  The message the form shows under a map row it will not apply, or `nil`:
  one asking whether a key is there without naming the key.
  """
  def row_error(%{path: [], operator: operator}) when operator in @key_operators,
    do: gettext("type the key to look for")

  def row_error(_row), do: nil

  @doc """
  The key path a visitor types, `price.to`, as the keys a row holds: split at
  each dot, each trimmed, blanks dropped.
  """
  def parse_path(text) when is_binary(text) do
    text
    |> String.split(".")
    |> Enum.map(&(&1 |> String.replace(<<0>>, "") |> String.trim()))
    |> Enum.reject(&(&1 == ""))
  end

  def parse_path(_text), do: []

  @doc "A row's key path as the form's input shows it: its keys joined by dots."
  def path_text(path) when is_list(path), do: Enum.map_join(path, ".", &to_string/1)
  def path_text(_path), do: ""

  @doc """
  What a map row's field and key path read as on a chip: "Changes › price ›
  to", or with no key, "Changes › any key".
  """
  def path_label(field_label, []), do: gettext("%{field} › any key", field: field_label)

  def path_label(field_label, path) when is_list(path),
    do: Enum.join([field_label | Enum.map(path, &to_string/1)], " › ")

  @doc """
  The Ash expression a map row filters by, on the attribute `name` of the
  resource the row is asked of, or `nil` when it filters by nothing: no
  value to compare with, or no key to look for.
  """
  def build(name, path, operator, value)

  def build(_name, [], operator, _value) when operator in @key_operators, do: nil

  def build(name, path, "has_key", _value), do: seen(name, matches(name, target(path)))

  def build(name, path, "missing_key", _value),
    do: expr(is_nil(^ref(name)) or not (^matches(name, target(path))))

  def build(name, path, operator, value) when operator in @operators do
    case text(value) do
      "" ->
        nil

      value ->
        case operator do
          "not_equals" -> seen(name, without(name, path, predicate("equals", value)))
          "not_contains" -> seen(name, without(name, path, predicate("contains", value)))
          operator -> seen(name, matches(name, filtered(path, predicate(operator, value))))
        end
    end
  end

  def build(_name, _path, _operator, _value), do: nil

  # A row is kept only where the reader may see the map. Ash reads a field a
  # field policy hides from them as `nil` where a filter names it, but never
  # reaches the column inside a fragment, which would answer from the value
  # they may not see: Contains, a character at a time, would read it back.
  # So the plain reference beside it decides first. Key Missing, above, keeps
  # a hidden map as one holding nothing, as Is Empty does a hidden field;
  # `ListUtils` refuses it on a map hidden on some rows, as it does Is Empty.
  defp seen(name, matches), do: expr(not is_nil(^ref(name)) and ^matches)

  # Not Equals and Not Contains keep a row whose map holds the key, with no
  # value there that equals or contains the one typed, as a column's Not
  # Equals keeps a row only where it has a value. A row lacking the key is
  # asked about with Missing Key. With no key named, a map that holds no such
  # value anywhere.
  defp without(name, path, predicate),
    do: expr(^matches(name, target(path)) and not (^matches(name, filtered(path, predicate))))

  # `@?` answers `NULL` for a row whose column is `NULL`, which `not` would
  # leave `NULL`; such a row holds no key and no value, so it reads `false`.
  # The path is bound as text and cast by Postgres, which Postgrex has no
  # type of its own for. A `?` in a fragment is a slot, so the operator's is
  # escaped.
  #
  # Built as the function itself rather than with `expr(fragment(...))`: a
  # filter's input, which a list's filter is read as so that its fields are
  # asked as a visitor may see them, takes no fragment by name, since a link
  # could otherwise write any SQL. This one is written here, never read from
  # the link, which only gives its path its keys and value.
  defp matches(name, json_path) do
    {:ok, fragment} =
      Ash.Query.Function.Fragment.new([
        "coalesce(? @\\? (?::text)::jsonpath, false)",
        ref(name),
        json_path
      ])

    fragment
  end

  # Where a row looks: the value at its key path, or with no key every value
  # at any depth, the map itself included.
  defp target([]), do: "$.**"
  defp target(path), do: "$" <> Enum.map_join(path, &("." <> string(&1)))

  defp filtered(path, predicate), do: "#{target(path)} ? (#{predicate})"

  # Equals is loose: a value typed as `10` matches the number, or text
  # reading as that number, `"10"` or `"10.00"`, and `true` the boolean or
  # the text, since a person cannot tell which a map holds from how it
  # reads. An audit row holds a decimal as text, `"229.00"`.
  defp predicate("equals", value) do
    ["@ == #{string(value)}"]
    |> Kernel.++(if number = number(value), do: ["@.number() == #{number}"], else: [])
    |> Kernel.++(if boolean = boolean(value), do: ["@ == #{boolean}"], else: [])
    |> Enum.join(" || ")
  end

  # Compared as numbers when the value is one, text reading as a number
  # included, and as text otherwise, so an ISO 8601 date compares by its
  # order in time. A value of the other kind does not match: `.number()` on
  # `"abc"` is an error, which `@?` reads as no match for that value alone.
  defp predicate(operator, value) when operator in ~w(gt gte lt lte) do
    case number(value) do
      nil -> "@ #{comparison(operator)} #{string(value)}"
      number -> "@.number() #{comparison(operator)} #{number}"
    end
  end

  # Case-insensitive, and literal: every character of the value that a
  # regular expression would read as syntax is escaped. `.string()` reads a
  # number or a boolean as text too, so Contains `10` finds `100`.
  defp predicate("contains", value), do: like("#{escape(value)}")
  defp predicate("starts_with", value), do: like("^#{escape(value)}")
  defp predicate("ends_with", value), do: like("#{escape(value)}$")

  defp like(pattern), do: ~s[@.string() like_regex #{string(pattern)} flag "i"]

  defp comparison("gt"), do: ">"
  defp comparison("gte"), do: ">="
  defp comparison("lt"), do: "<"
  defp comparison("lte"), do: "<="

  # A plain decimal, as written in JSON: `10`, `-3`, `1.50`, of at most 100
  # digits; a longer one is compared as text. Its leading zeros are dropped,
  # so `007` reads as `7`, which a path, as JSON, would refuse. Rewritten by
  # hand rather than through `Decimal`, which refuses more than about 40
  # digits by raising.
  defp number(value) do
    case Regex.run(~r/\A(-?)(\d{1,100})((?:\.\d{1,100})?)\z/, value) do
      [_value, sign, whole, fraction] ->
        whole = String.trim_leading(whole, "0")
        sign <> if(whole == "", do: "0", else: whole) <> fraction

      nil ->
        nil
    end
  end

  defp boolean(value) when value in ~w(true false), do: value
  defp boolean(_value), do: nil

  # A value as text, trimmed, whatever JSON a link carried it as.
  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: value |> String.replace(<<0>>, "") |> String.trim()
  defp text(value), do: value |> to_string() |> text()

  # A key or a string as a path writes one: a quoted JSON string, whose
  # escapes a path reads as JSON does. A NUL is dropped, which no `jsonb`
  # string can hold.
  defp string(value), do: value |> String.replace(<<0>>, "") |> JSON.encode!()

  # Each ASCII punctuation character a regular expression could read as
  # syntax, behind a backslash: Postgres reads a backslash before anything
  # but a letter or a digit as that character itself.
  defp escape(value),
    do: Regex.replace(~r/[\x21-\x2f\x3a-\x40\x5b-\x60\x7b-\x7e]/, value, "\\\\\\0")
end
