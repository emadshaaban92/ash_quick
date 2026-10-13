defmodule ExampleWeb.EmptiedTagsScenarioTest do
  @moduledoc """
  A multi-select emptied of its last pick posts no value under its name, only
  LiveSelect's `<name>_empty_selection` marker. The form must read that as an
  empty list, not as an absent field that falls back to the stored picks.

  The form helper merges in the `tags[]` hidden inputs still on the page, so
  the post an emptied select makes is pushed as it is.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.{RequiredAttachments, RequiredPicks}

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  test "emptying a required tag list says why, and the save keeps the stored tags",
       %{conn: conn} do
    record = picks_with_tags([:red, :blue])
    {:ok, view, _html} = live(conn, "/test/required_picks/#{record.id}/retag")

    assert picked_tags(view) == ["red", "blue"]

    render_change(view, "validate", emptied())

    assert picked_tags(view) == []
    assert errors(view) == ["pick at least one"]

    render_submit(view, "save", emptied())

    assert picked_tags(view) == []
    assert errors(view) == ["pick at least one"]
    assert Ash.get!(RequiredPicks, record.id).tags == [:red, :blue]
  end

  test "emptying a tag list the action lets be empty saves it empty", %{conn: conn} do
    record = picks_with_tags([:red])
    {:ok, view, _html} = live(conn, "/test/required_picks/#{record.id}/clear_tags")

    render_change(view, "validate", emptied())

    assert picked_tags(view) == []
    assert errors(view) == []

    render_submit(view, "save", emptied())

    assert Ash.get!(RequiredPicks, record.id).tags == []
  end

  defp picks_with_tags(tags) do
    owner = Ash.create!(RequiredAttachments, %{code: unique("R"), name: "Owner"})

    Ash.create!(RequiredPicks, %{code: unique("P"), kind: :small, tags: tags, owner_id: owner.id})
  end

  defp emptied, do: %{"form" => %{"tags_empty_selection" => ""}}

  # The picks the select renders, one hidden input each.
  defp picked_tags(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("input[name='form[tags][]']")
    |> LazyHTML.attribute("value")
  end

  defp errors(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("div[phx-feedback-for='form[tags]'] p.text-error")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
