defmodule ExampleWeb.ExportCeilingTest do
  @moduledoc """
  An export is refused, with words for it, when the list holds more rows than
  `:export_max_rows`. The ceiling is application configuration, so this runs
  alone.
  """
  use ExampleWeb.FeatureCase, async: false

  alias Example.Test.S3Stub

  @export_timeout to_timeout(second: 5)

  setup do
    Application.put_env(:ash_quick, :export_max_rows, 1)
    on_exit(fn -> Application.delete_env(:ash_quick, :export_max_rows) end)
  end

  test "a list over the ceiling is refused and nothing is stored", ctx do
    %{conn: conn, admin: admin} = ctx

    product(name: "Four-season tent", actor: admin)
    product(name: "Headlamp", actor: admin)

    {:ok, view, _html} = live(log_in(conn, admin), ~p"/products")

    view |> element("a", "CSV") |> render_click()
    render_async(view, @export_timeout)

    assert has_element?(view, "#ash-quick-export-modal", "Too many rows to export")
    assert has_element?(view, "#ash-quick-export-modal", "up to 1 rows")
    # The same list would be refused again, so there is nothing to retry.
    refute has_element?(view, "#ash-quick-export-modal button", "Retry")
    refute Enum.any?(S3Stub.keys(), &String.starts_with?(&1, "exports/#{admin.id}/"))
  end

  test "a list narrowed to the ceiling exports", ctx do
    %{conn: conn, admin: admin} = ctx

    product(name: "Four-season tent", actor: admin)
    product(name: "Headlamp", actor: admin)

    {:ok, view, _html} = live(log_in(conn, admin), ~p"/products?search=tent")

    view |> element("a", "CSV") |> render_click()
    render_async(view, @export_timeout)

    assert has_element?(view, "#ash-quick-export-modal a", "Download")
  end
end
