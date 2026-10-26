defmodule ExampleWeb.ShadowedArgumentScenarioTest do
  @moduledoc """
  An attachment argument named after a field of the record that is not an
  attachment (issue #103).

  A save with nothing picked used to fill the argument with whatever the record
  held under the same name: `%Ash.NotLoaded{}` for a calculation the form never
  loads, which crashed the save, or a value of another type. Only the record's
  own attachment attribute keeps what it holds; an argument takes its default,
  and the form neither shows nor posts back the record's value as its own.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.ShadowedArguments

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  test "a save with no upload leaves the arguments to their defaults", %{conn: conn} do
    record = Ash.create!(ShadowedArguments, %{code: unique("S"), cover: "front.png"})

    {:ok, view, html} = live(conn, "/test/shadowed_arguments/#{record.id}/ship")
    refute html =~ "front.png"

    view |> form("form[phx-submit=save]") |> render_submit()

    assert Ash.get!(ShadowedArguments, record.id).shipped_with == 0
  end
end
