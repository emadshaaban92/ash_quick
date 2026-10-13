defmodule ExampleWeb.SelectErrorsScenarioTest do
  @moduledoc """
  The select widgets follow the same rule as `input/1`: a field's error shows
  once the person used it or the form was submitted, not while something else
  on the form changes.

  `Example.Test.RequiredPicks.create` needs a relationship, an atom and an
  array of atoms, each drawn by a widget of its own rather than `input/1`.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.{RequiredAttachments, RequiredPicks}

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  @fields [owner_id: "is required", kind: "is required", tags: "pick at least one"]

  test "stay quiet while another field changes, and say why a save failed", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/test/required_picks/create")

    for {field, _message} <- @fields, do: assert(errors(view, field) == [])

    view |> form("form[phx-submit=save]") |> render_change(%{"form" => %{"code" => unique("P")}})

    for {field, _message} <- @fields,
        do: assert(errors(view, field) == [], "#{field} spoke early")

    view
    |> form("form[phx-submit=save]", %{"form" => %{"code" => unique("P")}})
    |> render_submit()

    for {field, message} <- @fields, do: assert(errors(view, field) == [message])
  end

  # A cleared select posts the same blank as one never touched, so only the
  # widget's memory of the pick can tell them apart.
  test "say what is missing once a pick is taken back", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/test/required_picks/create")
    owner = Ash.create!(RequiredAttachments, %{code: unique("R"), name: "Owner"})

    change(view, %{"owner_id" => owner.id, "kind" => "small", "tags" => ["red"]})

    for {field, _message} <- @fields, do: assert(errors(view, field) == [])

    # An emptied tag select drops its `tags[]` inputs and posts only this
    # marker, which the form helper cannot do while the inputs are on the page.
    render_change(view, "validate", %{
      "form" => %{
        "code" => unique("P"),
        "owner_id" => "",
        "kind" => "",
        "tags_empty_selection" => ""
      }
    })

    for {field, message} <- @fields, do: assert(errors(view, field) == [message])
  end

  test "on an update form, say what is missing once a stored value is cleared", %{conn: conn} do
    owner = Ash.create!(RequiredAttachments, %{code: unique("R"), name: "Owner"})

    record =
      Ash.create!(RequiredPicks, %{
        code: unique("P"),
        kind: :small,
        tags: [:red],
        owner_id: owner.id
      })

    {:ok, view, _html} = live(conn, "/test/required_picks/#{record.id}/update")

    assert errors(view, :kind) == []
    assert errors(view, :owner_id) == []

    change(view, %{"kind" => ""})

    assert errors(view, :kind) == ["is required"]
    assert errors(view, :owner_id) == []

    change(view, %{"owner_id" => ""})

    assert errors(view, :owner_id) == ["is required"]
  end

  defp change(view, params) do
    view |> form("form[phx-submit=save]") |> render_change(%{"form" => params})
  end

  # The messages rendered beside the field's select.
  defp errors(view, field) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("div[phx-feedback-for='form[#{field}]'] p.text-error")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
