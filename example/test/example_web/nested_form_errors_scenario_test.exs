defmodule ExampleWeb.NestedFormErrorsScenarioTest do
  @moduledoc """
  A save refused for want of a nested entry, and where a person reads about it.

  `Example.Test.RequiredEntries.create` needs at least one entry in an array of
  embeds. The form renders that field as sub-forms under an "Add" button, with
  no input of its own, so a save with none added posts nothing under it. The
  error belongs in the field's section once the form has been submitted, and
  not before.
  """
  use ExampleWeb.FeatureCase, async: true

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  test "a save with no entry says why it failed", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/test/required_entries/create")
    assert errors(view) == []

    view |> form("form[phx-submit=save]") |> render_change(%{"form" => %{"code" => unique("E")}})
    assert errors(view) == []

    view
    |> form("form[phx-submit=save]", %{"form" => %{"code" => unique("E")}})
    |> render_submit()

    assert errors(view) == ["add at least one"]
  end

  # The messages rendered inside the field's own section: the one holding its
  # "Add" button.
  defp errors(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("section:has(button[phx-value-path='form[entries]']) p.text-error")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
