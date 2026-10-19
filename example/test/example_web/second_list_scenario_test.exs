defmodule ExampleWeb.SecondListScenarioTest do
  @moduledoc """
  A list other than the page's default, reached through `?action=`, and worked
  like any list: paged, searched, and its URL corrected, all without leaving
  that list.

  Over `Example.Test.SecondLists`, whose `:index` lists oldest code first and
  whose `:newest_first` lists newest first, two rows a page. Its ETS table is
  written by this module alone, once, so the counts below are the whole table.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.SecondLists

  setup_all do
    for n <- 1..5 do
      SecondLists
      |> Ash.Changeset.for_create(:create, %{code: "Code #{n}"})
      |> Ash.create!(authorize?: false)
    end

    :ok
  end

  test "a second list pages, searches and corrects its URL without leaving it", %{
    conn: conn,
    admin: admin
  } do
    conn
    |> log_in(admin)
    |> visit(~p"/test/second_lists?action=newest_first")
    |> assert_has("*", text: "Showing 1-2 of 5")
    |> assert_has("td", text: "Code 5")
    |> refute_has("td", text: "Code 1")
    |> click_link("2")
    |> assert_has("*", text: "Showing 3-4 of 5")
    |> assert_has("td", text: "Code 3")
    |> refute_has("td", text: "Code 5")
    |> assert_path(~p"/test/second_lists",
      query_params: %{"action" => "newest_first", "page" => "2"}
    )
    |> click_link("[aria-label='Previous page']", "")
    |> assert_has("td", text: "Code 5")
    |> assert_path(~p"/test/second_lists", query_params: %{"action" => "newest_first"})
    |> fill_in("Search", with: "Code")
    |> assert_has("td", text: "Code 5")
    |> assert_path(~p"/test/second_lists",
      query_params: %{"action" => "newest_first", "search" => "Code"}
    )

    # The default size is left unsaid, and the list stays the one named.
    {:ok, view, _html} = live(log_in(conn, admin), ~p"/test/second_lists?action=newest_first")

    render_patch(view, ~p"/test/second_lists?action=newest_first&limit=2")
    assert_patch(view, ~p"/test/second_lists?action=newest_first&limit=2")
    assert_patch(view, ~p"/test/second_lists?action=newest_first")
    assert render(view) =~ "Code 5"
  end

  # The negative: the default list still writes no action at all.
  test "the default list names no action in its URL", %{conn: conn, admin: admin} do
    conn
    |> log_in(admin)
    |> visit(~p"/test/second_lists")
    |> assert_has("td", text: "Code 1")
    |> click_link("2")
    |> assert_has("td", text: "Code 3")
    |> assert_path(~p"/test/second_lists", query_params: %{"page" => "2"})
  end
end
