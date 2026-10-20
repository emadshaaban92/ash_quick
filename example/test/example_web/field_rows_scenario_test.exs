defmodule ExampleWeb.FieldRowsScenarioTest do
  @moduledoc """
  Each row on a details page names the field it shows, in `data-field`, so a
  test reads one field's value by its path rather than its label.

  `Example.Test.FieldRowsLive.Quick` lists an attribute, a relationship path
  one and two hops deep, and a field drawn by a widget; each row is named for
  its path whatever it is labelled or drawn with. The values hold `'` and `&`,
  which the HTML escapes and the visible text does not.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.FieldRows
  alias Example.Test.FieldRows.{City, Owner}

  @rows ["holder_name", "owner.name", "owner.city.name", "code"]

  setup %{conn: conn, admin: admin} do
    city = Ash.create!(City, %{name: "St. John's & Harbour"})
    owner = Ash.create!(Owner, %{name: "Smith & O'Neil Garage", city_id: city.id})

    record =
      Ash.create!(FieldRows, %{
        code: unique("R&D'"),
        holder_name: "O'Brien & Sons",
        owner_id: owner.id
      })

    {:ok, conn: log_in(conn, admin), record: record}
  end

  test "each row is named for its field's path, in the order listed", ctx do
    %{conn: conn, record: record} = ctx

    {:ok, view, _html} = live(conn, "/test/field_rows/#{record.id}")

    named =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("dl > div")
      |> Enum.flat_map(&LazyHTML.attribute(&1, "data-field"))

    assert named == @rows
  end

  test "a row's value is asserted as it reads, escaping aside", ctx do
    %{conn: conn, record: record} = ctx

    conn
    |> visit("/test/field_rows/#{record.id}")
    |> assert_has(~s([data-field="holder_name"] dd), text: "O'Brien & Sons", exact: true)
    |> assert_has(~s([data-field="owner.name"] dd), text: "Smith & O'Neil Garage", exact: true)
    |> assert_has(~s([data-field="owner.city.name"] dd),
      text: "St. John's & Harbour",
      exact: true
    )
    |> assert_has(~s([data-field="code"] dd), text: record.code, exact: true)
    |> assert_has(~s([data-field="code"] dt), text: "Reference", exact: true)
  end

  test "exact: true holds a row to the whole value", ctx do
    %{conn: conn, record: record} = ctx

    conn
    |> visit("/test/field_rows/#{record.id}")
    |> assert_has(~s([data-field="holder_name"] dd), text: "O'Brien")
    |> refute_has(~s([data-field="holder_name"] dd), text: "O'Brien", exact: true)
  end
end
