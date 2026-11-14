defmodule AshQuick.LiveView.StoredMapTest do
  @moduledoc """
  How a map whose shape is only known at runtime reads: summed up in a list
  cell, spelled out on a details page, one line in an export.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AshQuick.LiveView.Components.FieldValue
  alias AshQuick.LiveView.StoredMap

  defmodule Payload do
    @moduledoc false
    use Ash.Type.NewType, subtype_of: :map
  end

  describe "field?/1" do
    test "is a map, a NewType over one, or a list of either" do
      assert StoredMap.field?(%{type: Ash.Type.Map})
      assert StoredMap.field?(%{type: Payload})
      assert StoredMap.field?(%{type: {:array, Ash.Type.Map}})
      assert StoredMap.field?(%{type: {:array, Payload}})

      refute StoredMap.field?(%{type: Ash.Type.String})
      refute StoredMap.field?(%{type: {:array, Ash.Type.String}})
      refute StoredMap.field?(%{type: AshQuick.AshTypes.Text})
      refute StoredMap.field?(nil)
    end
  end

  describe "summary/1" do
    test "pairs each key with its value, keys in order" do
      assert StoredMap.summary(%{"total" => 10, "status" => "paid"}) ==
               {:pairs, [{"status", {:scalar, "paid"}}, {"total", {:scalar, 10}}], 0}
    end

    test "cuts a long value short" do
      {:pairs, [{"note", {:scalar, note}}], 0} =
        StoredMap.summary(%{"note" => String.duplicate("a", 100)})

      assert String.length(note) == 24
      assert String.ends_with?(note, "…")
    end

    test "shows the first keys of a bigger map, and how many more it has" do
      value = Map.new(1..6, &{"key#{&1}", &1})

      assert {:pairs, pairs, 2} = StoredMap.summary(value)
      assert Enum.map(pairs, &elem(&1, 0)) == ["key1", "key2", "key3", "key4"]
    end

    test "reads a small nested map inline, anything bigger by its size" do
      value = %{
        "price" => %{"from" => 1, "to" => 2},
        "tags" => %{"from" => [], "to" => ["a", "b"]},
        "meta" => Map.new(1..5, &{"k#{&1}", &1}),
        "items" => [1, 2]
      }

      assert StoredMap.summary(value) ==
               {:pairs,
                [
                  {"items", {:list, 2}},
                  {"meta", {:map, 5}},
                  {"price", {:inline, [{"from", {:scalar, 1}}, {"to", {:scalar, 2}}]}},
                  {"tags", {:inline, [{"from", {:list, 0}}, {"to", {:list, 2}}]}}
                ], 0}
    end

    test "reads a map inside a small nested map by its size" do
      assert StoredMap.summary(%{"x" => %{"to" => %{"amount" => 10}}}) ==
               {:pairs, [{"x", {:inline, [{"to", {:map, 1}}]}}], 0}
    end

    test "counts a list, and says when there is nothing" do
      assert StoredMap.summary([%{}, %{}]) == {:items, 2}
      assert StoredMap.summary(%{}) == :empty
      assert StoredMap.summary([]) == :empty
    end
  end

  describe "tree/2" do
    test "nests maps and lists, keys in order, items by position" do
      assert {[
                %{key: "a", kind: :scalar, value: 1},
                %{
                  key: "b",
                  kind: :list,
                  size: 2,
                  omitted: 0,
                  children: [
                    %{key: 1, kind: :scalar, value: "x"},
                    %{key: 2, kind: :map, size: 1, omitted: 0, children: [%{key: "c"}]}
                  ]
                }
              ], 0} = StoredMap.tree(%{"b" => ["x", %{"c" => nil}], "a" => 1})
    end

    test "stops building past its limit, counting what it left out" do
      value = %{"a" => Map.new(1..10, &{"k#{&1}", &1}), "b" => 1, "c" => 2}

      assert {[%{key: "a", children: children, omitted: 6}], 2} = StoredMap.tree(value, limit: 5)
      assert length(children) == 4
    end
  end

  describe "tree/2 on a deep value" do
    test "stops at its depth, each branch past it closed with its count" do
      chain = Enum.reduce(1..2000, %{"leaf" => "bottom"}, &%{"n#{&1}" => &2})

      {[top], 0} = StoredMap.tree(chain, depth: 3)

      assert %{key: "n2000", children: [%{key: "n1999", children: [cut]}]} = top
      assert %{key: "n1998", kind: :map, size: 1, children: [], omitted: 1} = cut
      assert levels(StoredMap.tree(chain) |> elem(0)) == 32
    end
  end

  defp levels([%{children: children}]), do: 1 + levels(children)
  defp levels([]), do: 0

  describe "json/2" do
    test "is one line, or indented when asked" do
      assert StoredMap.json(%{"a" => [1, 2]}) == ~s({"a":[1,2]})
      assert StoredMap.json(%{"a" => 1}, pretty: true) == "{\n  \"a\": 1\n}"
    end

    test "falls back to Elixir's own spelling for a value JSON cannot hold" do
      assert StoredMap.json(%{a: {1, 2}}) == "%{a: {1, 2}}"
    end
  end

  describe "a list cell" do
    defp cell(value, type \\ Ash.Type.Map) do
      render_component(&FieldValue.field_value/1,
        path: [],
        ash_field: %{type: type},
        value: value
      )
    end

    test "is one line however big the map is" do
      html = cell(%{"status" => "paid", "total" => 10})

      assert text(html) == "status: paid · total: 10"
      refute html =~ "<pre"

      assert text(cell(Map.new(1..40, &{"key#{&1}", &1}))) ==
               "key1: 1 · key10: 10 · key11: 11 · key12: 12 +36"
    end

    test "reads a small nested map inline, with the same values as the cell" do
      html = cell(%{"price" => %{"from" => 10, "to" => true}, "tags" => %{"to" => [1]}})

      assert text(html) == "price: {from: 10, to: Yes} · tags: {to: [1 item]}"
    end

    test "masks a redacted value inside a small nested map" do
      html = cell(%{"login" => %{"user" => "ada", "password" => "**redacted**", "seen" => nil}})

      assert text(html) =~ "{password: ********"
      assert text(html) =~ "seen: empty"
      refute text(html) =~ "**redacted**"
    end

    test "carries the whole value, cut short, as its tooltip" do
      assert cell(%{"a" => 1}) =~ ~s(title="{&quot;a&quot;:1}")
    end

    test "masks a redacted value" do
      assert text(cell(%{"password" => "**redacted**"})) =~ "password: ********"
    end

    test "counts a list of maps, and reads a NewType over a map" do
      assert text(cell([%{"a" => 1}, %{"b" => 2}], {:array, Ash.Type.Map})) == "2 items"
      assert text(cell(%{"a" => true}, Payload)) == "a: Yes"
    end
  end

  describe "a details page" do
    defp details(value, opts \\ []) do
      render_component(
        &FieldValue.field_value/1,
        [path: [], ash_field: %{type: Ash.Type.Map}, value: value, view: :details] ++ opts
      )
    end

    test "is a tree whose nested branches open with a click" do
      html =
        details(%{
          "price" => %{"from" => 1, "to" => 2},
          "tags" => Enum.map(1..8, &"tag#{&1}")
        })

      doc = LazyHTML.from_fragment(html)

      # A small branch of leaves starts open; a bigger one closed, with its count.
      assert [price] = doc |> LazyHTML.query(~s(li[data-key="price"] > details)) |> Enum.to_list()
      assert LazyHTML.attribute(price, "open") == [""]
      assert [tags] = doc |> LazyHTML.query(~s(li[data-key="tags"] > details)) |> Enum.to_list()
      assert LazyHTML.attribute(tags, "open") == []
      assert LazyHTML.text(tags) =~ "8 items"
    end

    test "cuts a long string, with the rest a click away" do
      long = String.duplicate("word ", 60)
      doc = details(%{"note" => long}) |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query(~s(li[data-key="note"] details summary)) |> LazyHTML.text() =~
               "Show all"
    end

    test "offers the raw JSON, copyable when the page names it" do
      html = details(%{"a" => 1}, dom_id: "log-field-3")

      assert html =~ ~s(id="log-field-3-raw")
      assert html =~ ~s(data-copy-from="log-field-3-raw")
      assert html =~ "Raw JSON"
      assert html =~ "&quot;a&quot;: 1"

      refute details(%{"a" => 1}) =~ "data-copy-from"
    end

    test "says how much a huge value left out" do
      html = details(Map.new(1..600, &{"key#{String.pad_leading("#{&1}", 3, "0")}", &1}))

      assert html =~ "100 more not shown; see Raw JSON"
    end

    test "draws a deep chain only to its depth" do
      chain = Enum.reduce(1..2000, %{"leaf" => "bottom"}, &%{"n#{&1}" => &2})
      html = details(chain)

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("details[open], details:not([open])")
             |> Enum.count() <= 34

      assert html =~ "1 more not shown; see Raw JSON"
    end

    test "offers no Raw JSON for an empty value" do
      html = details(%{})

      assert text(html) =~ "Empty"
      refute html =~ "Raw JSON"
    end

    test "leaves a struct to the clauses that know it" do
      html =
        render_component(&FieldValue.field_value/1,
          path: [],
          ash_field: %{type: Ash.Type.Map},
          value: ~D[2026-11-13]
        )

      refute html =~ "data-stored-map"
      assert html =~ "2026"
    end

    test "masks a redacted value" do
      html = details(%{"password" => "**redacted**"})

      tree = html |> LazyHTML.from_fragment() |> LazyHTML.query("ul") |> LazyHTML.text()

      assert tree =~ "********"
      refute tree =~ "**redacted**"
    end
  end

  defp text(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-stored-map]")
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
