defmodule AshQuick.LiveView.QuickFieldTest do
  @moduledoc """
  `QuickField.data_field/1` names a field by its path, and the details page puts
  that name on the field's row, whatever the row is labelled or drawn with.
  """
  use ExUnit.Case, async: true
  use Phoenix.Component

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias AshQuick.LiveView.Components.DetailsView
  alias AshQuick.LiveView.QuickField
  alias AshQuick.LiveView.QuickView.Options
  alias AshQuick.LiveView.URLParams
  alias AshQuick.Test.Lookup.{OtherName, PointsAtOtherName}

  doctest QuickField

  def widget(assigns) do
    ~H"""
    <span>{@value}</span>
    """
  end

  describe "data_field/1" do
    test "is the same for a path and the field normalized from it" do
      for {spec, name} <- [
            {:name, "name"},
            {{:name, "Called"}, "name"},
            {[target: :name], "target.name"},
            {{[target: :name], label: "Target"}, "target.name"},
            {{:target, [:name]}, "target.name"},
            {[target: [target: [target: :name]]], "target.target.target.name"},
            {{:name, label: "Drawn", widget: &__MODULE__.widget/1}, "name"},
            {[target: []], "target"},
            # A keyword list after a bare name is read as options, not a path.
            {{:target, [city: :name]}, "target"}
          ] do
        field = QuickField.normalize(spec)
        assert QuickField.data_field(spec) == name
        assert QuickField.data_field(field) == name
        assert QuickField.data_field(field.path) == name
      end
    end
  end

  test "each details row carries its field's name" do
    fields = [
      :name,
      {[target: :name], label: "Target"},
      {:name, label: "Drawn", widget: &__MODULE__.widget/1},
      [target: []]
    ]

    options =
      Options.new(__MODULE__.SomeQuickView, PointsAtOtherName,
        resource: PointsAtOtherName,
        details: [fields: fields]
      )

    rows =
      %{
        __changed__: nil,
        record: %PointsAtOtherName{
          id: "row-one",
          name: "O'Brien & Sons",
          target: %OtherName{id: "t", name: "Smith & Co"}
        },
        resource: PointsAtOtherName,
        scope: nil,
        options: options,
        fields: options.details_fields,
        base_path: "/points",
        params: %URLParams{default_limit: 20}
      }
      |> DetailsView.details_view()
      |> rendered_to_string()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("dl > div")
      |> Enum.map(fn row ->
        {LazyHTML.attribute(row, "data-field"),
         row |> LazyHTML.query("dd") |> LazyHTML.text() |> String.trim()}
      end)

    assert rows == [
             {["name"], "O'Brien & Sons"},
             {["target.name"], "Smith & Co"},
             {["name"], "O'Brien & Sons"},
             {["target"], "Smith & Co"}
           ]
  end
end
