defmodule AshQuick.LiveView.Components.WidgetPathTest do
  @moduledoc """
  A widget on a relationship path, rendered for a record whose relationship is
  empty.

  `{[target: :name], widget: ...}` hands the widget whatever is at the end of
  the path. When `target` is a nullable `belongs_to` left unset there is
  nothing at the end of it, and the widget is handed `nil` — the details page
  and the list used to raise there instead, on a `Map.get(nil, :name)`.
  """
  use ExUnit.Case, async: true
  use Phoenix.Component

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias AshQuick.LiveView.Components.{DetailsView, ListView}
  alias AshQuick.LiveView.QuickField
  alias AshQuick.LiveView.QuickView
  alias AshQuick.LiveView.QuickView.Options
  alias AshQuick.LiveView.URLParams
  alias AshQuick.Test.Lookup.{OtherName, PointsAtOtherName}

  def widget(assigns) do
    ~H"""
    <span class="widget-value">{inspect(@value)}</span>
    """
  end

  @fields [:name, {[target: :name], label: "Target", widget: &__MODULE__.widget/1}]

  defp options do
    Options.new(__MODULE__.SomeQuickView, PointsAtOtherName,
      resource: PointsAtOtherName,
      list: [fields: @fields],
      details: [fields: @fields]
    )
  end

  defp record(target) do
    %PointsAtOtherName{
      id: "row-one",
      name: "Row Name",
      target_id: target && target.id,
      target: target
    }
  end

  describe "QuickField.resolve_value/2" do
    test "walks a relationship path that is there" do
      assert QuickField.resolve_value(record(%OtherName{id: "t", name: "Target Name"}), [
               {:target, :name}
             ]) == "Target Name"
    end

    test "is nil past an empty relationship" do
      assert QuickField.resolve_value(record(nil), [{:target, :name}]) == nil
      assert QuickField.resolve_value(record(nil), [{:target, [{:target, :name}]}]) == nil
    end
  end

  test "the details page hands the widget nil for an empty relationship" do
    options = options()

    html =
      %{
        __changed__: nil,
        record: record(nil),
        resource: PointsAtOtherName,
        scope: nil,
        options: options,
        fields: options.details_fields,
        base_path: "/points",
        params: %URLParams{},
        print_actions: [],
        print_data: nil
      }
      |> DetailsView.details_view()
      |> rendered_to_string()

    assert html =~ ~s(<span class="widget-value">nil</span>)
  end

  test "the list hands the widget nil for an empty relationship" do
    options = options()
    action = Ash.Resource.Info.action(PointsAtOtherName, options.list_default_action)

    assigns = %{
      __changed__: %{},
      resource: PointsAtOtherName,
      scope: nil,
      path: "/points",
      base_path: "/points",
      params: %URLParams{},
      routed_shapes: [],
      filters: nil,
      selected_rows: %{},
      action_running: false,
      row_actions: nil,
      export_data: nil,
      print_data: nil,
      data: %{results: [record(nil)], count: 1, limit: 20, offset: 0}
    }

    socket =
      QuickView.prepare_assigns(%Phoenix.LiveView.Socket{assigns: assigns}, action, options)

    html = socket.assigns |> ListView.list_view() |> rendered_to_string()

    assert html =~ ~s(<span class="widget-value">nil</span>)
  end
end
