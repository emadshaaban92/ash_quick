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

  describe "build_ash_filter/2" do
    test "Ends With is Ash's own predicate, with the value as typed" do
      filter = %CustomFilter{row("name") | operator: "ends_with", value: "50%_"}

      assert CustomFilter.build_ash_filter(filter) == %{"name" => %{"string_ends_with" => "50%_"}}
    end

    test "Not Contains is Contains under `not`" do
      filter = %CustomFilter{row("name") | operator: "not_contains", value: "x"}

      assert CustomFilter.build_ash_filter(filter) == %{
               "not" => %{"name" => %{"contains" => "x"}}
             }
    end

    test "Is Empty and Is Not Empty take no value" do
      for {operator, is_nil?} <- [{"is_nil", true}, {"is_not_nil", false}] do
        filter = %CustomFilter{row("note") | operator: operator, value: ""}

        assert CustomFilter.applied?(filter)
        assert CustomFilter.build_ash_filter(filter) == %{"note" => %{"is_nil" => is_nil?}}
      end
    end

    # A string kept as typed can hold `""`, which reads as blank in the list.
    test "Is Empty on a string also keeps a blank one" do
      fields = %{"note" => %{type: Ash.Type.String}, "salary" => %{type: Ash.Type.Integer}}
      empty = %CustomFilter{row("note") | operator: "is_nil"}
      not_empty = %CustomFilter{row("note") | operator: "is_not_nil"}

      assert CustomFilter.build_ash_filter(empty, fields: fields) == %{
               "or" => [%{"note" => %{"is_nil" => true}}, %{"note" => %{"eq" => ""}}]
             }

      assert CustomFilter.build_ash_filter(not_empty, fields: fields) == %{
               "and" => [%{"note" => %{"is_nil" => false}}, %{"note" => %{"not_eq" => ""}}]
             }

      # A type built on a string holds one too.
      text = %{"body" => %{type: AshQuick.AshTypes.Text}}
      body = %CustomFilter{row("body") | operator: "is_nil"}

      assert CustomFilter.build_ash_filter(body, fields: text) == %{
               "or" => [%{"body" => %{"is_nil" => true}}, %{"body" => %{"eq" => ""}}]
             }

      salary = %CustomFilter{row("salary") | operator: "is_nil"}

      assert CustomFilter.build_ash_filter(salary, fields: fields) ==
               %{"salary" => %{"is_nil" => true}}
    end

    test "Any Of keeps the values picked, and filters by nothing without one" do
      filter = %CustomFilter{row("stage") | operator: "in", value: ["draft", "", "live"]}
      assert CustomFilter.build_ash_filter(filter) == %{"stage" => %{"in" => ["draft", "live"]}}

      # A link can hand it one value rather than a list.
      filter = %CustomFilter{row("stage") | operator: "in", value: "draft"}
      assert CustomFilter.build_ash_filter(filter) == %{"stage" => %{"in" => ["draft"]}}

      filter = %CustomFilter{row("stage") | operator: "in", value: []}
      refute CustomFilter.applied?(filter)
      assert CustomFilter.build_ash_filter(filter) == nil
    end

    test "On Day is the day's instants in the zone given" do
      filter = %CustomFilter{row("stamped_at") | operator: "on", value: "2026-10-22"}

      assert CustomFilter.build_ash_filter(filter, timezone: "Etc/UTC") == %{
               "stamped_at" => %{"gte" => "2026-10-22T00:00:00Z", "lt" => "2026-10-23T00:00:00Z"}
             }
    end
  end

  describe "cast_row_value/4" do
    @stamp %{type: Ash.Type.UtcDatetimeUsec, constraints: []}

    test "reads On Day's value as a date" do
      assert CustomFilter.cast_row_value(@stamp, "on", "2026-10-22", "Etc/UTC") ==
               {:ok, ~D[2026-10-22]}

      assert {:error, _} = CustomFilter.cast_row_value(@stamp, "on", "2026-13-45", "Etc/UTC")
    end

    # As `build_ash_filter/2` reads it: a datetime is no date, though Ecto's
    # date cast would drop its time.
    test "refuses a datetime as On Day's value" do
      assert {:error, _} =
               CustomFilter.cast_row_value(@stamp, "on", "2026-10-22T10:00:00", "Etc/UTC")
    end

    # Read in a zone the time zone database cannot load, the date names no
    # instants, and the read would refuse the whole filter.
    test "refuses On Day's date in a zone that cannot be loaded" do
      assert CustomFilter.cast_row_value(@stamp, "on", "2026-10-22", "Nowhere/Zone") ==
               {:error, "is invalid"}
    end
  end

  test "reject_rows/2 drops the rows it is asked to, and answers nil for none" do
    filter = group([row("note"), %CustomFilter{row("memo") | operator: "is_nil"}])

    kept = CustomFilter.reject_rows(filter, &(&1.operator == "is_nil"))

    assert [%{field_name: "note"}] = kept.children
    assert CustomFilter.reject_rows(nil, fn _ -> true end) == nil
  end

  # Compared as written, a timestamp would cast a bare date as its midnight
  # UTC, and a datetime string as that instant, and the read would accept it.
  test "On Day filters by nothing with a value that is no day" do
    for value <- ["2026-10-22T10:00:00", "2026-13-45", 20_261_022] do
      filter = %CustomFilter{row("stamped_at") | operator: "on", value: value}

      assert CustomFilter.build_ash_filter(filter, timezone: "Etc/UTC") == nil
    end

    filter = %CustomFilter{row("stamped_at") | operator: "on", value: "2026-10-22"}
    assert CustomFilter.build_ash_filter(filter, timezone: "Nowhere/Zone") == nil
  end

  describe "reshape_value/3" do
    test "keeps a value its new operator takes the same way" do
      assert CustomFilter.reshape_value("a", "equals", "contains") == "a"
      assert CustomFilter.reshape_value(["a"], "in", "in") == ["a"]
    end

    test "moves one value in and out of a list" do
      assert CustomFilter.reshape_value("a", "equals", "in") == ["a"]
      assert CustomFilter.reshape_value("", "equals", "in") == []
      assert CustomFilter.reshape_value(["", "b", "c"], "in", "equals") == "b"
      assert CustomFilter.reshape_value([], "in", "equals") == ""
    end

    # An instant is no date, and Is Empty compares with nothing.
    test "drops a value its new operator cannot read" do
      assert CustomFilter.reshape_value("2026-10-22T10:00:00Z", "gt", "on") == ""
      assert CustomFilter.reshape_value("2026-10-22", "on", "gt") == ""
      assert CustomFilter.reshape_value("a", "equals", "is_nil") == ""
      assert CustomFilter.reshape_value("", "is_nil", "in") == []
    end
  end

  test "values/1 names each of a list's values" do
    filter = group([%CustomFilter{row("stage") | operator: "in", value: ["a", 2]}])

    assert CustomFilter.values(filter) == ["a", "2"]
  end
end
