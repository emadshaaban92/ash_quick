defmodule AshQuick.LiveView.NumberColumns do
  @moduledoc false
  # The list's columns that hold numbers: an integer, a float, a decimal or a
  # `Money`, on the resource or through a relationship path, a type of the
  # host's own built on one of those included. The list draws their cells and
  # their headers against the column's right edge, in digits of one width, so
  # a column of amounts lines up by its units the way a ledger does. A number
  # reads left to right on a right-to-left page too (`FieldValue` isolates it
  # as such), so its units sit at its right there as well, and the column is
  # pinned to the right rather than to the page's end.
  #
  # A column drawn by a widget is left as the widget draws it, and so is a
  # number with a fixed set of values, which the list names rather than prints.
  # The details page shows each value alone on its own row and is left alone.

  alias AshQuick.LiveView.EnumOptions
  alias AshQuick.LiveView.QuickField

  @number_types [Ash.Type.Integer, Ash.Type.Float, Ash.Type.Decimal]

  # AshMoney's type, named rather than referenced: AshQuick does not depend on
  # AshMoney.
  @money_type AshMoney.Types.Money

  @doc false
  # The `QuickField.data_field/1` names of the columns among `fields` that hold
  # numbers, for `resource`, the resource the list reads.
  def columns(fields, resource) do
    for %QuickField{widget: nil, path: path} = field <- fields,
        number?(resource, path),
        do: QuickField.data_field(field)
  end

  defp number?(resource, name) when is_atom(name) do
    case Ash.Resource.Info.field(resource, name) do
      # An aggregate's struct carries no type: Ash works it out from its kind
      # and the field it reads.
      %Ash.Resource.Aggregate{} = aggregate ->
        case Ash.Resource.Info.aggregate_type(resource, aggregate) do
          {:ok, type} -> number_type?(type)
          _ -> false
        end

      %{type: type} = field ->
        number_type?(type) and EnumOptions.kind(field) == nil

      _ ->
        false
    end
  end

  defp number?(resource, [{relationship, nested}]) when is_atom(nested) or is_list(nested) do
    case Ash.Resource.Info.relationship(resource, relationship) do
      %{destination: destination} -> number?(destination, nested)
      nil -> false
    end
  end

  defp number?(_resource, _path), do: false

  defp number_type?({:array, _type}), do: false

  defp number_type?(type) do
    type = Ash.Type.get_type(type)

    type =
      if Ash.Type.NewType.new_type?(type), do: Ash.Type.NewType.subtype_of(type), else: type

    type in @number_types or type == @money_type
  end
end
