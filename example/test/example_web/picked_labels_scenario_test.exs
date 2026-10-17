defmodule ExampleWeb.PickedLabelsScenarioTest do
  @moduledoc """
  An id-list argument edits the relationship its `manage_relationship` change
  names, whatever it is called. `Example.Test.PickedLabels` edits its
  `:labels` through `:picks`, a name that says nothing about them.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.PickedLabels
  alias Example.Test.PickedLabels.Label

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  test "the create form offers the labels to pick from", %{conn: conn} do
    label = Ash.create!(Label, %{name: unique("Label")})

    session = conn |> visit("/test/picked_labels/create")

    assert label.name in dropdown_entries(session, "Labels")
  end

  test "the update form starts from the labels the record has", %{conn: conn} do
    [kept, other] = for _ <- 1..2, do: Ash.create!(Label, %{name: unique("Label")})
    record = Ash.create!(PickedLabels, %{code: unique("P"), picks: [kept.id]})

    {:ok, view, _html} = live(conn, "/test/picked_labels/#{record.id}/update")

    picked =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s(input[name="form[picks][]"]))
      |> Enum.flat_map(&LazyHTML.attribute(&1, "value"))

    assert picked == [kept.id]
    refute other.id in picked
  end
end
