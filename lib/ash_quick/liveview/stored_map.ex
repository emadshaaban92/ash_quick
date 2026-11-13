defmodule AshQuick.LiveView.StoredMap do
  @moduledoc """
  A field that holds a map whose shape is only known at runtime: an
  `Ash.Type.Map` (a `:map` attribute, `jsonb` on Postgres), an
  `Ash.Type.NewType` over one, or a list of either. An audit row's `changes`
  is one: each row's keys are the attributes its write touched.

  The list and details pages and the exports read such a value here, so it
  reads the same wherever it shows:

    * `summary/1` is what a list cell shows: a map's first keys with their
      values in short form, a list as its count.
    * `tree/2` is what a details page shows: every key and value, nested
      maps and lists as branches, cut off after a number of entries so a
      huge value does not hang the page.
    * `json/2` is the value as JSON, pretty for a details page's Raw JSON
      and compact for an export cell.

  Keys read in sorted order, so a value reads the same however it was
  stored. Writing such a value is the host's own business: no form is
  offered for one.

  Kept out of `AshQuick.Components` on purpose: that module is imported whole
  into every QuickView, where a public function would collide with any host
  helper of the same name.
  """

  alias Ash.Type.NewType

  # Ash's own marker for a value it will not print (`Ash.Helpers.redact/1`),
  # which an audit row stores in place of a sensitive attribute's value.
  @redacted "**redacted**"

  # How much of a map a list cell shows inline: at most this many keys, each
  # value cut to this many characters, each key to that many.
  @inline_keys 4
  @inline_value_length 24
  @key_length 24

  @typedoc """
  A branch or leaf of `tree/2`. `key` is the map key it was stored under, or
  the item's position, counted from 1, in a list. A `:map` or `:list` node
  holds its `size`, the `children` shown and how many were `omitted`.
  """
  @type tree_node ::
          %{key: String.t() | pos_integer, kind: :scalar, value: term}
          | %{
              key: String.t() | pos_integer,
              kind: :map | :list,
              size: non_neg_integer,
              children: [tree_node],
              omitted: non_neg_integer
            }

  @doc """
  Whether `field` holds a map of unknown shape, or a list of them: its type
  is `Ash.Type.Map`, or an `Ash.Type.NewType` over it.
  """
  @spec field?(%{type: Ash.Type.t()} | nil) :: boolean
  def field?(%{type: {:array, type}}), do: map_type?(type)
  def field?(%{type: type}), do: map_type?(type)
  def field?(_field), do: false

  defp map_type?(Ash.Type.Map), do: true

  defp map_type?(type) when is_atom(type) do
    NewType.new_type?(type) and map_type?(NewType.subtype_of(type))
  end

  defp map_type?(_type), do: false

  @doc """
  What a list cell shows for `value`:

    * `:empty` for an empty map or list;
    * `{:pairs, [{key, short}], more}` for a map: its first #{@inline_keys}
      keys, each with its value in `t:short/0` form, and how many keys it
      has past those;
    * `{:items, count}` for a list.
  """
  @spec summary(map | list) ::
          :empty
          | {:pairs, [{String.t(), short}], non_neg_integer}
          | {:items, pos_integer}
  def summary(value) when value == %{} or value == [], do: :empty
  def summary(value) when is_list(value), do: {:items, length(value)}

  def summary(value) when is_map(value) do
    {shown, rest} = value |> entries() |> Enum.split(@inline_keys)

    {:pairs, Enum.map(shown, fn {key, v} -> {cut(key, @key_length), short(v)} end), length(rest)}
  end

  @typedoc """
  A value as a list cell shows it:

    * `{:scalar, value}`, a string cut short;
    * `{:inline, [{key, value}]}` for a small map, read as
      `{key: value, ...}`: each value a scalar cut short, or a nested map or
      list by its size;
    * `{:map, size}` or `{:list, length}` for a bigger map, or any list.
  """
  @type short ::
          {:scalar, term}
          | {:inline,
             [{String.t(), {:scalar, term} | {:map, non_neg_integer} | {:list, non_neg_integer}}]}
          | {:map, non_neg_integer}
          | {:list, non_neg_integer}

  defp short(value)
       when value != %{} and is_non_struct_map(value) and map_size(value) <= @inline_keys do
    {:inline, Enum.map(entries(value), fn {key, v} -> {cut(key, @key_length), size(v)} end)}
  end

  defp short(value), do: size(value)

  defp size(value) when is_list(value), do: {:list, length(value)}
  defp size(value) when is_non_struct_map(value), do: {:map, map_size(value)}
  defp size(value), do: {:scalar, cut_value(value)}

  @doc """
  `value`'s entries as `t:tree_node/0`s, and how many top-level entries were
  left out. Nodes are counted depth first, each key or item one, and none is
  built past `:limit` (default 500): a branch reached after that holds no
  children, and says how many it left out. Nor is one built deeper than
  `:depth` (default 32) branches: a chain of nested maps would otherwise
  spend the whole limit on one path, and a page nested that deep is more than
  a browser will draw.
  """
  @spec tree(map | list, keyword) :: {[tree_node], non_neg_integer}
  def tree(value, opts \\ []) do
    limit = Keyword.get(opts, :limit, 500)
    depth = Keyword.get(opts, :depth, 32)
    {nodes, omitted, _budget} = children(value, limit, depth)
    {nodes, omitted}
  end

  defp children(value, budget, 0), do: {[], count(value), budget}

  defp children(value, budget, depth) do
    {nodes, budget, omitted} =
      value
      |> entries()
      |> Enum.reduce({[], budget, 0}, fn
        _entry, {nodes, 0, omitted} ->
          {nodes, 0, omitted + 1}

        {key, v}, {nodes, budget, omitted} ->
          {node, budget} = tree_node(key, v, budget - 1, depth - 1)
          {[node | nodes], budget, omitted}
      end)

    {Enum.reverse(nodes), omitted, budget}
  end

  defp tree_node(key, value, budget, depth) when is_list(value) or is_non_struct_map(value) do
    {children, omitted, budget} = children(value, budget, depth)
    kind = if is_list(value), do: :list, else: :map

    {%{key: key, kind: kind, size: count(value), children: children, omitted: omitted}, budget}
  end

  defp tree_node(key, value, budget, _depth),
    do: {%{key: key, kind: :scalar, value: value}, budget}

  defp count(value) when is_list(value), do: length(value)
  defp count(value), do: map_size(value)

  @doc """
  `value` as JSON: compact by default, indented with `pretty: true`. A value
  JSON cannot hold (a tuple, a pid) reads as Elixir writes it instead.
  """
  @spec json(term, keyword) :: String.t()
  def json(value, opts \\ []) do
    pretty? = Keyword.get(opts, :pretty, false)

    case Jason.encode(value, pretty: pretty?) do
      {:ok, json} -> json
      {:error, _} -> inspect(value, pretty: pretty?, limit: :infinity, printable_limit: :infinity)
    end
  end

  @doc """
  Whether `value` is the mark Ash stores in place of a value it would not
  print.
  """
  @spec redacted?(term) :: boolean
  def redacted?(value), do: value == @redacted

  @doc """
  `text` cut to `length` characters, with an ellipsis when it was longer.
  """
  @spec cut(String.t(), pos_integer) :: String.t()
  def cut(text, length) do
    if String.length(text) > length, do: String.slice(text, 0, length - 1) <> "…", else: text
  end

  # A map's entries in key order, keys as text; a list's items keyed by
  # position, counted from 1.
  defp entries(value) when is_list(value) do
    value |> Enum.with_index(1) |> Enum.map(fn {item, i} -> {i, item} end)
  end

  defp entries(value) when is_map(value) do
    value
    |> Enum.map(fn {key, v} -> {key_text(key), v} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp key_text(key) when is_binary(key), do: key
  defp key_text(key) when is_atom(key), do: Atom.to_string(key)
  defp key_text(key), do: inspect(key)

  defp cut_value(value) when is_binary(value) do
    if redacted?(value), do: value, else: cut(value, @inline_value_length)
  end

  defp cut_value(value), do: value
end
