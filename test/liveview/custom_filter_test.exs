defmodule AshQuick.LiveView.CustomFilterTest do
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.Components.FilterForm
  alias AshQuick.LiveView.CustomFilter
  alias AshQuick.LiveView.FilterField

  defp row(field), do: CustomFilter.new_leaf(%{field_name: field, operator: "equals"})

  # The fields a row names, by name, as `CustomFilter.fields_by_name/2` gives
  # them: only a field's type is read.
  defp typed(types) do
    Map.new(types, fn {name, type} ->
      {name, %FilterField{name: name, spec: nil, field: %{type: type}, resource: nil}}
    end)
  end

  defp group(children),
    do: %CustomFilter{uuid: Ash.UUID.generate(), operator: "and", children: children}

  describe "visible/4" do
    alias AshQuick.Test.Exposure.Payslip

    @actor %{id: "8d3c5f0e-2a7b-4c1d-9e6f-0b1a2c3d4e5f"}

    # `amount` is hidden from everyone, whichever record it is read from.
    test "leaves out a field hidden on every record the read reads" do
      action = Ash.Resource.Info.action(Payslip, :index)
      fields = CustomFilter.filterable_fields(Payslip)

      assert :amount in Enum.map(fields, & &1.spec)
      refute :amount in (fields |> CustomFilter.visible(action, @actor) |> Enum.map(& &1.spec))
    end

    # As a form drawn with no action given asks.
    test "leaves every field in with no read to ask" do
      fields = CustomFilter.filterable_fields(Payslip)

      assert CustomFilter.visible(fields, nil, @actor) == fields
      assert CustomFilter.visible(fields, nil, @actor, filter_is: false) == fields
    end
  end

  describe "filterable_fields/2" do
    alias AshQuick.Test.Filter.Ledger

    defp offered(resource, names \\ nil),
      do: resource |> CustomFilter.filterable_fields(names) |> Enum.map(& &1.spec)

    # Ash refuses it under an `or` or a `not`, or named twice, and a row of
    # the form can be any of those.
    test "leave out a field Ash filters by simple equality only" do
      refute :reference in offered(Ledger)
      refute :reference in offered(Ledger, [:name, :reference])
      refute CustomFilter.filterable_field?(Ledger, :reference)
    end

    test "leave out a field that is not filterable" do
      refute :note in offered(Ledger)
    end

    # On a data layer that filters in SQL, the read would raise.
    test "leave out a calculation computed in Elixir only" do
      refute :shouted in offered(Ledger)
      refute CustomFilter.filterable_field?(Ledger, :shouted)
    end

    # Shown masked, and a filter would give it back: rows that start with
    # "4", then "43", and so on.
    test "leave out a sensitive field, of the resource or through a relationship" do
      alias AshQuick.Test.Filter.Posting

      refute :pin in offered(Ledger)
      refute :pin in offered(Ledger, [:name, :pin])
      refute CustomFilter.filterable_field?(Ledger, :pin)
      refute CustomFilter.filterable_field?(Posting, {:ledger, :pin})
      assert offered(Posting, ledger: :name, ledger: :pin) == [{:ledger, :name}]
    end

    test "keep an expression calculation and the plain fields" do
      assert offered(Ledger) == [:id, :name, :whispered]
    end

    # `:defaults` stands for the fields offered unsaid, in their order, so a
    # list adds a related field without copying them out.
    test "offer the fields offered unsaid where `:defaults` is named" do
      alias AshQuick.Test.Filter.Posting

      assert offered(Posting, [:defaults, ledger: :name]) == [:id, :memo, {:ledger, :name}]
      assert offered(Posting, [{:ledger, :name}, :defaults]) == [{:ledger, :name}, :id, :memo]
      assert offered(Ledger, [:defaults]) == offered(Ledger)
    end

    # The marker is always the marker: a field named `defaults` is offered
    # through it, beside the other defaults, and cannot be named alone.
    test "read `:defaults` as the marker on a resource with a field of that name" do
      alias AshQuick.Test.Filter.Preset

      assert offered(Preset) == [:id, :name, :defaults]
      assert offered(Preset, [:defaults]) == [:id, :name, :defaults]
      assert offered(Preset, [:name, :defaults]) == [:name, :id, :defaults]
    end

    test "offer a field named beside `:defaults` once, where it is named first" do
      alias AshQuick.Test.Filter.Posting

      assert offered(Posting, [:memo, :defaults, :id]) == [:memo, :id]
      assert offered(Posting, [:defaults, :defaults]) == [:id, :memo]
    end
  end

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
      fields = typed(%{"note" => Ash.Type.String, "salary" => Ash.Type.Integer})
      empty = %CustomFilter{row("note") | operator: "is_nil"}
      not_empty = %CustomFilter{row("note") | operator: "is_not_nil"}

      assert CustomFilter.build_ash_filter(empty, fields: fields) == %{
               "or" => [%{"note" => %{"is_nil" => true}}, %{"note" => %{"eq" => ""}}]
             }

      assert CustomFilter.build_ash_filter(not_empty, fields: fields) == %{
               "and" => [%{"note" => %{"is_nil" => false}}, %{"note" => %{"not_eq" => ""}}]
             }

      # A type built on a string holds one too.
      text = typed(%{"body" => AshQuick.AshTypes.Text})
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

    test "Has Any Of asks whether a list holds a value picked" do
      filter = %CustomFilter{row("tags") | operator: "has_any", value: ["sale", "", "new"]}

      assert CustomFilter.build_ash_filter(filter) ==
               %{"tags" => %{"intersects" => ["sale", "new"]}}

      filter = %CustomFilter{row("tags") | operator: "has_any", value: "sale"}
      assert CustomFilter.build_ash_filter(filter) == %{"tags" => %{"intersects" => ["sale"]}}

      filter = %CustomFilter{row("tags") | operator: "has_any", value: []}
      refute CustomFilter.applied?(filter)
      assert CustomFilter.build_ash_filter(filter) == nil
    end

    # A list with nothing in it reads as empty in the list, as `nil` does.
    test "Is Empty on a list also keeps one holding nothing" do
      fields = typed(%{"tags" => {:array, Ash.Type.Atom}})
      empty = %CustomFilter{row("tags") | operator: "is_nil"}
      not_empty = %CustomFilter{row("tags") | operator: "is_not_nil"}

      assert CustomFilter.build_ash_filter(empty, fields: fields) == %{
               "or" => [%{"tags" => %{"is_nil" => true}}, %{"tags" => %{"eq" => []}}]
             }

      assert CustomFilter.build_ash_filter(not_empty, fields: fields) == %{
               "and" => [%{"tags" => %{"is_nil" => false}}, %{"tags" => %{"not_eq" => []}}]
             }
    end

    # Inside `exists`, where Ash applies the related resource's read policies
    # to the related record alone.
    test "asks of a field through a relationship inside exists" do
      filter = %CustomFilter{row("owner.name") | operator: "starts_with", value: "Ad"}

      assert CustomFilter.build_ash_filter(filter) ==
               Ash.Query.Exists.new([:owner], %{"name" => %{"string_starts_with" => "Ad"}})

      filter = %CustomFilter{row("owner.name") | operator: "not_contains", value: "x"}

      assert CustomFilter.build_ash_filter(filter) ==
               Ash.Query.Exists.new([:owner], %{"not" => %{"name" => %{"contains" => "x"}}})

      filter = %CustomFilter{row("owner.tier") | operator: "in", value: ["gold"]}

      assert CustomFilter.build_ash_filter(filter) ==
               Ash.Query.Exists.new([:owner], %{"tier" => %{"in" => ["gold"]}})
    end

    # A row with no owner, or one its reader may not read, has an empty
    # owner's name, as the list shows it.
    test "Is Empty through a relationship is no related record holding a value" do
      fields = typed(%{"owner.name" => Ash.Type.String})
      filled = %{"and" => [%{"name" => %{"is_nil" => false}}, %{"name" => %{"not_eq" => ""}}]}
      empty = %CustomFilter{row("owner.name") | operator: "is_nil"}
      not_empty = %CustomFilter{row("owner.name") | operator: "is_not_nil"}

      assert CustomFilter.build_ash_filter(empty, fields: fields) ==
               %{"not" => Ash.Query.Exists.new([:owner], filled)}

      assert CustomFilter.build_ash_filter(not_empty, fields: fields) ==
               Ash.Query.Exists.new([:owner], filled)
    end

    # A link can carry any JSON, and Ash's filter input reads a name where an
    # operator goes as an operator, a field or a relationship: `brand` with
    # `name` as its operator and a map as its value once read as
    # `%{"brand" => %{"name" => %{"contains" => "x"}}}`.
    test "a row is read only by an operator the form offers, with one value or a list" do
      for {operator, value} <- [
            {"name", %{"contains" => "x"}},
            {"eq", "x"},
            {"equals", %{"contains" => "x"}},
            {"equals", ["x", "y"]},
            {"in", [%{"contains" => "x"}]},
            {"in", [["x"]]}
          ] do
        filter = %CustomFilter{row("brand") | operator: operator, value: value}

        assert CustomFilter.build_ash_filter(filter) == nil
        refute CustomFilter.readable?(filter)
      end

      assert CustomFilter.build_ash_filter(%CustomFilter{row("name") | value: "x"}) ==
               %{"name" => %{"equals" => "x"}}
    end

    # The allow-list repeats what `FilterForm` offers: an operator the form
    # gained and the list did not would apply, write its URL, and be dropped
    # from it on the next read. One the list holds and the form never offers
    # is one a link reaches and the form cannot show. A `Money` is offered
    # equality and comparisons, as a number is; the package has no AshMoney
    # to build one with.
    test "reads every operator the form offers, and only those" do
      enum = %{type: Ash.Type.Atom, constraints: [one_of: [:a, :b]]}
      enums = %{type: {:array, Ash.Type.Atom}, constraints: [items: [one_of: [:a, :b]]]}

      fields =
        [enum, enums] ++
          Enum.map(CustomFilter.offered_types(), &%{type: &1, constraints: []})

      offered = fields |> Enum.flat_map(&FilterForm.offered_operators/1) |> Enum.uniq()

      for operator <- offered do
        value = if CustomFilter.value_shape(operator) == :list, do: ["x"], else: "x"
        assert CustomFilter.readable?(%CustomFilter{row("f") | operator: operator, value: value})
      end

      assert Enum.sort(offered) == Enum.sort(CustomFilter.operators())
    end

    test "a group is read only when it joins its rows by `and` or `or`" do
      leaf = %CustomFilter{row("name") | value: "x"}

      for operator <- ["brand", "not", nil] do
        assert CustomFilter.build_ash_filter(%CustomFilter{group([leaf]) | operator: operator}) ==
                 nil
      end

      assert CustomFilter.build_ash_filter(%CustomFilter{group([leaf]) | operator: "or"}) ==
               %{"or" => [%{"name" => %{"equals" => "x"}}]}
    end

    test "with `:fields`, a row on any other field filters by nothing" do
      fields = typed(%{"name" => Ash.Type.String})
      name = %CustomFilter{row("name") | value: "x"}
      brand = %CustomFilter{row("brand") | value: "x"}

      assert CustomFilter.build_ash_filter(group([name, brand]), fields: fields) ==
               %{"and" => [%{"name" => %{"equals" => "x"}}]}
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

    # Each value is one item of the list, cast as Ash casts a filter's: an
    # atom's is left the string it was picked as.
    test "reads Has Any Of's values as items of the list" do
      tags = %{type: {:array, Ash.Type.Atom}, constraints: [items: [one_of: [:new, :sale]]]}

      assert CustomFilter.cast_row_value(tags, "has_any", ["sale", "", "new"]) ==
               {:ok, ["sale", "new"]}

      counts = %{type: {:array, Ash.Type.Integer}, constraints: []}
      assert CustomFilter.cast_row_value(counts, "has_any", ["1", "2"]) == {:ok, [1, 2]}
      assert {:error, _} = CustomFilter.cast_row_value(counts, "has_any", ["1", "x"])
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
