defmodule AshQuick.LiveView.EnumOptions do
  @moduledoc """
  The values a field offers to pick from, and the label each one shows.

  Two kinds of type hold a fixed set of values: an `Ash.Type.Enum` module,
  whose values and labels are its own (`values/0`, `label/1`), and an atom
  constrained by `one_of`, whose labels are `AshQuick.LiveView.Utils.humanize/1`
  of each value. Given the resource the field belongs to, a label the resource
  declares for a value (`label :status, :paid_off, "Paid Off in Full"`, see
  `AshQuick`) is drawn in place of either. Each is translated
  (`AshQuick.Labels.translate/2`), under the resource's and field's context
  when given the resource, so a value reads in the reader's language. A `Ash.Type.NewType` over either counts as what it wraps. An
  atom without `one_of` holds no fixed set: it is typed in, like a string.

  Forms, the custom filter and the list and details pages all read their
  options and labels here, so a value reads the same everywhere it shows.

  Kept out of `AshQuick.Components` on purpose: that module is imported whole
  into every QuickView, where a public function would collide with any host
  helper of the same name.
  """

  alias Ash.Type.NewType
  alias AshQuick.Labels
  alias AshQuick.LiveView.Utils

  @typedoc "A field, or anything with the field's `:type` and `:constraints`."
  @type field :: %{required(:type) => Ash.Type.t(), optional(:constraints) => keyword}

  @doc """
  Whether `field` is picked from a fixed set: `:single` for one value,
  `:array` for a list of them, or `nil` when it holds no fixed set.
  """
  @spec kind(field | nil) :: :single | :array | nil
  def kind(%{type: {:array, type}} = field) do
    if values(type, constraints(field)[:items] || []), do: :array
  end

  def kind(%{type: type} = field) do
    if values(type, constraints(field)), do: :single
  end

  def kind(_field), do: nil

  @doc """
  The `{label, value}` pairs `field` of `resource` offers, in the order its
  type lists them, or `[]` when it holds no fixed set. For a list field, the
  pairs of one item.
  """
  @spec options(field, Ash.Resource.t() | nil) :: [{String.t(), atom | String.t()}]
  def options(field, resource \\ nil) do
    field
    |> english_options(resource)
    |> Enum.map(fn {label, value} ->
      {Labels.translate(label, context(field, resource)), value}
    end)
  end

  @doc false
  # The pairs before translating: the msgids `mix ash_quick.gen.gettext` lists.
  def english_options(field, resource \\ nil) do
    {type, constraints} = item_type(field)

    type
    |> values(constraints)
    |> List.wrap()
    |> Enum.map(&{english_label(type, field, resource, &1), &1})
  end

  @doc false
  # The values `field` offers, or `nil` when it holds no fixed set.
  def values(field) do
    {type, constraints} = item_type(field)
    values(type, constraints)
  end

  @doc """
  The options whose label holds `search`, ignoring case: what a person types
  into a select is matched against what they read, not the stored value.
  """
  @spec search([{String.t(), term}], String.t() | nil) :: [{String.t(), term}]
  def search(options, search) when search in [nil, ""], do: options

  def search(options, search) do
    search = String.downcase(search)

    Enum.filter(options, fn {label, _value} ->
      String.contains?(String.downcase(label), search)
    end)
  end

  @doc """
  The label `value` shows as in `field` of `resource`: the label the resource
  declares for that value, else its enum's label when the field is typed by an
  `Ash.Type.Enum`, and `AshQuick.LiveView.Utils.humanize/1` otherwise, `field`
  given or not, translated (`AshQuick.Labels.translate/2`).
  """
  @spec label(field | nil, atom | String.t(), Ash.Resource.t() | nil) :: String.t()
  def label(field, value, resource \\ nil)

  def label(nil, value, _resource), do: Labels.name(value)

  def label(field, value, resource) do
    {type, _constraints} = item_type(field)
    type |> english_label(field, resource, value) |> Labels.translate(context(field, resource))
  end

  # A value is translated under its resource and field: "Cancelled" agrees
  # with the noun its field describes.
  defp context(field, resource), do: Labels.context(resource, Map.get(field, :name))

  defp english_label(type, field, resource, value) do
    Labels.declared(resource, {Map.get(field, :name), value}) ||
      case enum(type) do
        nil -> Utils.humanize(value)
        enum -> enum_label(enum, value)
      end
  end

  # An enum's `label/1` matches only its own values, and an overridden one may
  # answer nil. A stored value the enum no longer lists still shows.
  defp enum_label(enum, value) do
    if value in enum.values(),
      do: enum.label(value) || Utils.humanize(value),
      else: Utils.humanize(value)
  end

  defp item_type(%{type: {:array, type}} = field), do: {type, constraints(field)[:items] || []}
  defp item_type(%{type: type} = field), do: {type, constraints(field)}

  defp constraints(field), do: Map.get(field, :constraints) || []

  defp values(Ash.Type.Atom, constraints), do: constraints[:one_of]

  defp values(type, constraints) when is_atom(type) do
    cond do
      enum = enum(type) ->
        enum.values()

      new_type?(type) ->
        values(NewType.subtype_of(type), NewType.constraints(type, constraints))

      true ->
        nil
    end
  end

  defp values(_type, _constraints), do: nil

  # The `Ash.Type.Enum` module a type is, or wraps through `Ash.Type.NewType`.
  defp enum(type) when is_atom(type) do
    cond do
      not Code.ensure_loaded?(type) -> nil
      Spark.implements_behaviour?(type, Ash.Type.Enum) -> type
      new_type?(type) -> enum(NewType.subtype_of(type))
      true -> nil
    end
  end

  defp enum(_type), do: nil

  defp new_type?(type), do: Code.ensure_loaded?(type) and NewType.new_type?(type)
end
