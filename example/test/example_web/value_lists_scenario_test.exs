defmodule ExampleWeb.ValueListsScenarioTest do
  @moduledoc """
  A list of values shows each item as a badge of its own, on the list and on
  the details page, with no character between them: a comma, a dash or a
  semicolon could be read as part of a value (`-5`, `1,000`) or as the
  separator of an export's file.

  `Example.Test.ValueLists` holds the lists, one of each kind.
  """
  use ExampleWeb.FeatureCase, async: true

  alias AshQuick.LiveView.Components.FieldValue
  alias Example.Test.ValueLists

  setup %{admin: admin} do
    record =
      Ash.Seed.seed!(ValueLists, %{
        code: unique("LISTS"),
        words: ["red", "green"],
        readings: [-1_000, -3],
        weights: [Decimal.new("1.50"), Decimal.new("-2")],
        fees: [Money.new(:USD, 5), Money.new(:USD, 1_000)]
      })

    parts =
      for name <- ["Bolt", "Nut"] do
        Ash.Seed.seed!(ValueLists.Part, %{name: name, value_list_id: record.id})
      end

    {:ok, admin: admin, record: record, parts: parts}
  end

  # Each list's badges and links. The space between badges, which keeps the
  # items apart in the text a cell is copied as, is the component test's to
  # read: `live/2` drops whitespace between elements, where a browser keeps
  # it. The LRM and RLM marks a locale writes around a number are left out:
  # they are not what is asked here.
  defp badges(conn, user, path, scope) do
    {:ok, _view, html} = conn |> log_in(user) |> live(path)

    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#{scope} [role=list]")
    |> Enum.map(fn list ->
      items =
        list
        |> LazyHTML.query("[role=listitem].badge")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim() |> plain()))

      links = list |> LazyHTML.query("[role=listitem] > a") |> LazyHTML.attribute("href")
      {items, links}
    end)
  end

  defp plain(text), do: String.replace(text, ["\u200E", "\u200F"], "")

  defp pages(conn, user, record) do
    [
      badges(conn, user, ~p"/test/value_lists", "tr:has(a[href$='#{record.id}'])"),
      badges(conn, user, ~p"/test/value_lists/#{record.id}", "[data-field]")
    ]
  end

  test "the list and the details page show each item as a badge", ctx do
    %{conn: conn, admin: admin, record: record} = ctx

    for shown <- pages(conn, admin, record) do
      assert [
               {["red", "green"], []},
               {["-1,000", "-3"], []},
               {["1.50", "-2"], []},
               {["$5.00", "$1,000.00"], []},
               {parts, []}
             ] = shown

      assert Enum.sort(parts) == ["Bolt", "Nut"]
    end
  end

  # A page links a related record only where its reader may open that
  # record's page, which no test page grants: the linker is handed in here.
  test "related records named by their label are each a linked badge", ctx do
    %{record: record, parts: [bolt, nut]} = ctx
    record = Ash.load!(record, :parts)

    html =
      render_component(&FieldValue.field_value/1,
        value: record,
        path: {:parts, [:name]},
        linker: &"/parts/#{&1.id}"
      )

    links =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[role=list] > [role=listitem].badge > a")

    assert links |> Enum.map(&String.trim(LazyHTML.text(&1))) |> Enum.sort() == ["Bolt", "Nut"]

    assert links |> LazyHTML.attribute("href") |> Enum.sort() ==
             Enum.sort(["/parts/#{bolt.id}", "/parts/#{nut.id}"])
  end

  test "an Arabic reader gets the same badges", ctx do
    %{conn: conn, admin: admin, record: record} = ctx
    arabic = Ash.update!(admin, %{locale: :ar}, actor: admin)

    for shown <- pages(conn, arabic, record) do
      assert [
               {["red", "green"], []},
               {["-1,000", "-3"], []},
               {["1.50", "-2"], []},
               {["5.00\u00A0US$", "1,000.00\u00A0US$"], []},
               {parts, []}
             ] = shown

      assert Enum.sort(parts) == ["Bolt", "Nut"]
    end
  end
end
