defmodule ExampleWeb.CellFilterLiveScenarioTest do
  @moduledoc """
  A cell's filter menu left open while a live update changes the cell: the
  entry the reader clicks is the one applied, or nothing is.

  `async: false`: `:refetch_window` coalesces refetches and is application
  env, zeroed here so a write's refetch reaches the page at once.
  """
  use ExampleWeb.FeatureCase, async: false

  @refused "That filter couldn&#39;t be applied to this list"

  setup %{conn: conn, admin: admin} do
    previous = Application.fetch_env(:ash_quick, :refetch_window)
    Application.put_env(:ash_quick, :refetch_window, 0)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash_quick, :refetch_window, value)
        :error -> Application.delete_env(:ash_quick, :refetch_window)
      end
    end)

    {:ok, conn: log_in(conn, admin), prefix: unique("Live cell ")}
  end

  # The menu still reads "Has Sale" at its first place, where the cell's
  # choices now hold "Has New": the pick is refused, not applied as New.
  test "an entry whose cell changed under the open menu filters by nothing", %{
    conn: conn,
    admin: admin,
    prefix: prefix
  } do
    product = product(actor: admin, name: "#{prefix}a", tags: [:sale, :new])
    view = products(conn, prefix)
    menu = ~s(tr[id="#{product.id}"] [data-cell-filter="tags"])

    view |> element(menu <> " [role=button]") |> render_click()
    assert texts(view, menu <> " li") == ["Has Sale", "Has New"]

    # The tags change without a notification of their own; the deactivation
    # beside them publishes one, and the row is read again with both.
    Ash.Seed.update!(product, %{tags: [:new]})
    Ash.update!(product, action: :deactivate, actor: admin)

    assert eventually(fn -> "No" in texts(view, ~s(tr[id="#{product.id}"] td)) end)
    assert texts(view, menu <> " li") == ["Has Sale", "Has New"]

    view
    |> element(menu <> ~s( button[data-cell-filter-choice="has_any"]), "Sale")
    |> render_click()

    assert render(view) =~ @refused
    assert chips(view) == ["Name starts with #{prefix}"]
  end

  # Reopened once the cell changed, the menu reads what the cell holds now,
  # and its entries apply.
  test "a menu reopened after its cell changed offers what it holds now", %{
    conn: conn,
    admin: admin,
    prefix: prefix
  } do
    product = product(actor: admin, name: "#{prefix}a", tags: [:sale, :new])
    view = products(conn, prefix)
    menu = ~s(tr[id="#{product.id}"] [data-cell-filter="tags"])

    view |> element(menu <> " [role=button]") |> render_click()
    assert texts(view, menu <> " li") == ["Has Sale", "Has New"]

    Ash.Seed.update!(product, %{tags: [:new]})
    Ash.update!(product, action: :deactivate, actor: admin)
    assert eventually(fn -> "No" in texts(view, ~s(tr[id="#{product.id}"] td)) end)

    view |> element(menu <> " [role=button]") |> render_click()
    assert texts(view, menu <> " li") == ["Has New"]

    view
    |> element(menu <> ~s( button[data-cell-filter-choice="has_any"]), "New")
    |> render_click()

    assert_patch(view)
    refute render(view) =~ @refused
    assert chips(view) == ["Name starts with #{prefix}", "Tags has any of New"]
  end

  defp eventually(check, tries \\ 40) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(check, tries - 1)
    end
  end

  defp products(conn, prefix) do
    filter =
      %{
        "operator" => "and",
        "children" => [%{"field_name" => "name", "operator" => "starts_with", "value" => prefix}]
      }
      |> JSON.encode!()
      |> :base64.encode()
      |> URI.encode_www_form()

    {:ok, view, _html} = live(conn, "/products?custom_filter=#{filter}")
    view
  end

  defp chips(view) do
    view
    |> texts("[data-filter-chip] > span[id$='-text']")
    |> Enum.map(&String.replace(&1, ~r/\s+/, " "))
  end

  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim() |> String.replace(~r/\s+/, " ")))
  end
end
