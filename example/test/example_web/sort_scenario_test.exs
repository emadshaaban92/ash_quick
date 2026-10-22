defmodule ExampleWeb.SortScenarioTest do
  @moduledoc """
  Sorting a list by a column: a click on its header sorts by it ascending,
  then descending, then back to the list's own order, one column at a time,
  with the sort carried in the URL as `?sort=`.

  Over `Example.Test.SortedRows`, two rows a page. `/test/sorted_rows` leaves
  `sortable` unsaid, so its sortable columns are its attributes, expression
  calculations and relationship paths Ash sorts; `/test/sorted_rows_named`
  names one relationship path and nothing else, and orders by rank, highest
  first. The ETS table is written by this module alone, once, so the rows
  below are the whole table.
  """
  use ExampleWeb.FeatureCase, async: true

  alias AshQuick.LiveView.QuickView.Options
  alias Example.Test.S3Stub
  alias Example.Test.SortedRows
  alias Example.Test.SortedRows.Owner

  @export_timeout to_timeout(second: 5)

  setup_all do
    owners = Map.new(["Zed", "Amy", "Kim"], &{&1, Ash.create!(Owner, %{name: &1})})

    for {code, rank, owner} <- [
          {"Alpha", 3, "Zed"},
          {"Bravo", 1, "Amy"},
          {"Charlie", 2, "Kim"},
          {"Delta", 4, "Amy"}
        ] do
      SortedRows
      |> Ash.Changeset.for_create(:seed, %{code: code, rank: rank, owner_id: owners[owner].id})
      |> Ash.create!(authorize?: false)
    end

    :ok
  end

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  describe "the columns a list may be sorted by" do
    test "unsaid, are the columns Ash sorts, through relationships too", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/test/sorted_rows")

      # Not the list, the Elixir calculation, nor the path through a
      # relationship marked `sortable? false`.
      assert sort_links(view) == ["code", "rank", "negated", "owner.name"]
    end

    test "named, are exactly those", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/test/sorted_rows_named")

      assert sort_links(view) == ["owner.name"]
    end

    test "are only list columns Ash can sort, checked when the QuickView compiles" do
      message =
        Exception.message(
          assert_raise(ArgumentError, fn ->
            options(
              sortable: [:shouted, :tags, :owner, :inserted, [keeper: :name], [owner: :name]]
            )
          end)
        )

      assert message =~ "lets its list be sorted by columns it cannot be sorted by"
      assert message =~ "* :shouted is not a field Ash can sort by"
      assert message =~ "* :tags is not a field Ash can sort by"
      assert message =~ "* :owner is not a field Ash can sort by"
      assert message =~ "* :inserted is not one of the list's fields"
      assert message =~ "* [keeper: :name] is not a field Ash can sort by"
      refute message =~ "* [owner: :name]"
    end

    test "can be none" do
      assert %Options{list_sortable: []} = options(sortable: [])
    end
  end

  describe "a header click" do
    test "sorts ascending, then descending, then back to the list's order", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/test/sorted_rows")

      assert codes(view) == ["Alpha", "Bravo"]

      view |> element(~s(th a[data-sort="rank"])) |> render_click()
      assert_patch(view, ~p"/test/sorted_rows?sort=rank")
      assert codes(view) == ["Bravo", "Charlie"]
      assert has_element?(view, ~s(th[aria-sort="ascending"] a[data-sort="rank"]))

      view |> element(~s(th a[data-sort="rank"])) |> render_click()
      assert_patch(view, ~p"/test/sorted_rows?sort=-rank")
      assert codes(view) == ["Delta", "Alpha"]
      assert has_element?(view, ~s(th[aria-sort="descending"] a[data-sort="rank"]))

      view |> element(~s(th a[data-sort="rank"])) |> render_click()
      assert_patch(view, ~p"/test/sorted_rows")
      assert codes(view) == ["Alpha", "Bravo"]
      refute has_element?(view, "th[aria-sort]")
    end

    test "on another column sorts by that one instead", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/test/sorted_rows?sort=-rank")

      view |> element(~s(th a[data-sort="code"])) |> render_click()
      assert_patch(view, ~p"/test/sorted_rows?sort=code")
    end

    test "starts from the first page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/test/sorted_rows?page=2")

      view |> element(~s(th a[data-sort="rank"])) |> render_click()
      assert_patch(view, ~p"/test/sorted_rows?sort=rank")
    end
  end

  describe "a sorted list" do
    test "sorts by an expression calculation", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/test/sorted_rows?sort=negated")

      assert codes(view) == ["Delta", "Alpha"]
    end

    test "sorts through a relationship, ties in the action's order", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/test/sorted_rows?sort=owner.name")

      # Both Amy's; the action's own sort, by code, orders them.
      assert codes(view) == ["Bravo", "Delta"]

      {:ok, view, _html} = live(conn, ~p"/test/sorted_rows?sort=-owner.name&page=2")

      assert codes(view) == ["Bravo", "Delta"]
    end

    test "breaks its ties by the QuickView's sort_by before the action's", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/test/sorted_rows_named?sort=owner.name")

      # Both Amy's; `sort_by`, rank highest first, orders them, not the code.
      assert codes(view) == ["Delta", "Bravo"]

      {:ok, view, _html} = live(conn, ~p"/test/sorted_rows_named?sort=-owner.name&page=2")

      assert codes(view) == ["Delta", "Bravo"]
    end

    test "pages through in that order, and its pager says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/test/sorted_rows?sort=-rank")

      assert has_element?(view, ~s(.join a[href="/test/sorted_rows?page=2&sort=-rank"]))

      {:ok, view, _html} = live(conn, ~p"/test/sorted_rows?sort=-rank&page=2")

      assert codes(view) == ["Charlie", "Bravo"]
    end

    test "keeps its sort through a search", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/test/sorted_rows?sort=-rank")

      # The action ignores the search, so every row still matches.
      view |> form("#search-form", %{search: "a"}) |> render_change()
      assert_patch(view, ~p"/test/sorted_rows?search=a&sort=-rank")
      assert codes(view) == ["Delta", "Alpha"]
    end

    test "exports in that order", %{conn: conn, admin: admin} do
      {:ok, view, _html} = live(conn, ~p"/test/sorted_rows?sort=-rank")

      view |> element("a", "CSV") |> render_click()
      render_async(view, @export_timeout)

      [_header | rows] = admin |> exported_csv() |> String.split("\r\n", trim: true)

      assert Enum.map(rows, &(&1 |> String.split(",") |> hd())) ==
               ["Delta", "Alpha", "Charlie", "Bravo"]
    end
  end

  describe "a sort the list does not offer" do
    for column <- ["shouted", "tags", "keeper.name", "id", "nonexistent", ""] do
      test "?sort=#{column} is dropped", %{conn: conn} do
        {:ok, view, _html} = live(conn, "/test/sorted_rows?sort=-#{unquote(column)}")

        assert codes(view) == ["Alpha", "Bravo"]
        refute has_element?(view, "th[aria-sort]")
        assert has_element?(view, ~s(.join a[href="/test/sorted_rows?page=2"]))
      end
    end

    test "on a page that names its columns, a default one is dropped too", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/test/sorted_rows_named?sort=code")

      # In `sort_by`'s order, rank highest first, not by code.
      assert codes(view) == ["Delta", "Alpha"]
    end
  end

  defp options(list_opts) do
    Options.new(__MODULE__.SomeQuickView, SortedRows,
      resource: SortedRows,
      list:
        [fields: [:code, :tags, :shouted, :owner, [owner: :name], [keeper: :name]]] ++ list_opts
    )
  end

  defp sort_links(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("thead a[data-sort]")
    |> Enum.flat_map(&LazyHTML.attribute(&1, "data-sort"))
  end

  defp codes(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("tbody tr td:nth-child(2)")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  # Exports are keyed by the actor, and every test makes its own users — so this
  # finds exactly the file this test's click produced.
  defp exported_csv(actor) do
    key = "exports/#{actor.id}/"

    assert body =
             Enum.find_value(1..40, fn _attempt ->
               case Enum.find(S3Stub.keys(), &String.contains?(&1, key)) do
                 nil ->
                   Process.sleep(25)
                   nil

                 key ->
                   S3Stub.body(key)
               end
             end),
           "nothing was uploaded under #{key}"

    body
  end
end
