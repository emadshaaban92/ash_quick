defmodule ExampleWeb.SelectErrorsScenarioTest do
  @moduledoc """
  The select widgets follow the same rule as `input/1`: a field's error shows
  once the person used it or the form was submitted, not while something else
  on the form changes.

  `Example.Test.RequiredPicks.create` needs a relationship, an atom and an
  array of atoms, each drawn by a widget of its own rather than `input/1`.
  """
  use ExampleWeb.FeatureCase, async: true

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

  # The messages rendered beside the field's select.
  defp errors(view, field) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("div[phx-feedback-for='form[#{field}]'] p.text-error")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
