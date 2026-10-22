defmodule AshQuick.LiveView.CustomFilterTest do
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.CustomFilter

  defp row(field), do: CustomFilter.new_leaf(%{field_name: field, operator: "equals"})

  defp group(children),
    do: %CustomFilter{uuid: Ash.UUID.generate(), operator: "and", children: children}

  describe "reject_fields/2" do
    test "drops the rows naming a field, in nested groups too" do
      filter = group([row("salary"), row("code"), group([row("salary"), row("name")])])

      kept = CustomFilter.reject_fields(filter, ["salary"])

      assert [%{field_name: "code"}, %{children: [%{field_name: "name"}]}] = kept.children
      assert CustomFilter.field_names(kept) == ["code", "name"]
    end

    test "leaves no filter when the root is itself such a row" do
      assert CustomFilter.reject_fields(row("salary"), ["salary"]) == nil

      assert %CustomFilter{field_name: "code"} =
               CustomFilter.reject_fields(row("code"), ["salary"])
    end

    test "builds nothing from a group left empty" do
      kept = CustomFilter.reject_fields(group([row("salary")]), ["salary"])

      assert CustomFilter.build_ash_filter(kept) == nil
    end
  end

  test "Starts With is Ash's own predicate, with the value as typed" do
    filter = %CustomFilter{row("name") | operator: "starts_with", value: "50%_"}

    assert CustomFilter.build_ash_filter(filter) == %{"name" => %{"string_starts_with" => "50%_"}}
  end
end
