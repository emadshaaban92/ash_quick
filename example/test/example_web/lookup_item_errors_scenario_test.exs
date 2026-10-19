defmodule ExampleWeb.LookupItemErrorsScenarioTest do
  @moduledoc """
  A failed save holding a sub-form built for a read action (issue #81).

  `Example.Test.LookupItems.create` only relates items it looks up, so
  AshPhoenix builds each item a post sends for a read action. The page never
  adds one, but a hand-sent post can, and the save failing must not take the
  page down.
  """
  use ExampleWeb.FeatureCase, async: true

  alias AshQuick.LiveView.ActionErrors

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  test "a failed save holding a read item says what is wrong", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/test/lookup_items/create")

    html = render_submit(view, "save", %{"form" => post("")})

    assert html =~ "is required"
    refute html =~ ActionErrors.forbidden_message()
  end

  test "a validate holding a read item keeps the page up", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/test/lookup_items/create")

    html = render_change(view, "validate", %{"form" => post(unique("L"))})

    assert html =~ "lookup_items"
    # Only the bookkeeping AshPhoenix keeps on every sub-form is drawn for it.
    assert html
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(~s{[name^="form[items][0]"]:not([type=hidden])})
           |> Enum.to_list() == []
  end

  defp post(code),
    do: %{
      "code" => code,
      "items" => %{"0" => %{"_form_type" => "read", "id" => Ash.UUIDv7.generate()}}
    }
end
