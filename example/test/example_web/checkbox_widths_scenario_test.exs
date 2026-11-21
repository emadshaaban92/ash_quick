defmodule ExampleWeb.CheckboxWidthsScenarioTest do
  @moduledoc """
  A checkbox takes half a form grid's row on `sm` and up, like every other
  input, so the field after it starts where it would after any other.

  `Example.Test.CheckboxWidths` holds a boolean between two fields at the top
  level and inside an embed's sub-form.
  """
  use ExampleWeb.FeatureCase, async: true

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  test "a checkbox's wrapper spans two columns, at the top level and in a sub-form",
       %{conn: conn} do
    conn
    |> visit(~p"/test/checkbox_widths/create")
    |> assert_has("div.sm\\:col-span-2 > input#form_code")
    |> assert_has("div.sm\\:col-span-2 > label > input#form_active[type='checkbox']")
    |> assert_has("div.sm\\:col-span-2 > input#form_note")
    |> assert_has("input[name='form[settings][enabled]'][type='checkbox']")
    |> assert_has(
      "div.sm\\:col-span-2 > label > input[name='form[settings][enabled]'][type='checkbox']"
    )
    |> assert_has("div.sm\\:col-span-2 > input[name='form[settings][label]']")
  end
end
