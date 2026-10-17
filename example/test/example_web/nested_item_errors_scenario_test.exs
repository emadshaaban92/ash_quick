defmodule ExampleWeb.NestedItemErrorsScenarioTest do
  @moduledoc """
  A save refused for an error on one of its sub-forms, and where a person reads
  about it (issue #78).

  `Example.Test.NestedItems.create` brings its items along through
  `manage_relationship`, each item a sub-form built for the item's own create,
  and each item's parts a sub-form under it. When one of them is refused, the
  error is filed at its path, and the parent form has nothing to say about any
  of its own inputs. That is still an input error, not the policy refusing the
  save.
  """
  use ExampleWeb.FeatureCase, async: true

  require Ash.Query

  alias AshQuick.LiveView.ActionErrors

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  test "an error on an item's input shows under that input, and only there", %{conn: conn} do
    view = with_items(conn, 1)

    code = unique("N")
    html = save(view, code, %{"0" => %{"status" => "blocked"}})

    assert item_errors(html) == ["is blocked"]
    assert flash(html) == ""
    assert saved(code) == []
  end

  test "an error the item's create returns on save shows under its input", %{conn: conn} do
    view = with_items(conn, 1)

    html = save(view, unique("N"), %{"0" => %{"status" => "late"}})

    assert item_errors(html) == ["is refused on save"]
    assert flash(html) == ""
  end

  test "an error on a field an item has no input for is flashed with the item", %{conn: conn} do
    view = with_items(conn, 2)

    html =
      save(view, unique("N"), %{"0" => %{"status" => "hidden"}, "1" => %{"status" => "hidden"}})

    assert flash(html) =~ "Items 1 › Note: is hidden"
    assert flash(html) =~ "Items 2 › Note: is hidden"
    refute flash(html) =~ ActionErrors.forbidden_message()
  end

  test "an item failing for no input's reason is not called a refusal", %{conn: conn} do
    view = with_items(conn, 1)

    html = save(view, unique("N"), %{"0" => %{"status" => "broken"}})

    assert flash(html) == ActionErrors.generic_message()
  end

  test "an error two levels down shows under its input or names both items", %{conn: conn} do
    view = with_items(conn, 1)
    add_form(view, "form[items][0][parts]")
    add_form(view, "form[items][0][parts]")

    html =
      save(view, unique("N"), %{
        "0" => %{
          "status" => "fine",
          "parts" => %{"0" => %{"name" => "bad"}, "1" => %{"name" => "secret"}}
        }
      })

    assert part_errors(html) == ["is bad"]
    assert flash(html) =~ "Items 1 › Parts 2 › Code: is secret"
    refute flash(html) =~ "is bad"
  end

  # The save posts the emptied single sub-form back, so it is rebuilt before the
  # walk; this holds the page to saying what is wrong either way.
  test "a save after the address is removed still says what is wrong", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/test/nested_items/create")
    render_click(view, "remove-form", %{"path" => "form[address]"})

    html =
      view
      |> form("form[phx-submit=save]", %{"form" => %{"code" => ""}})
      |> render_submit()

    assert html =~ "is required"
    refute flash(html) =~ ActionErrors.forbidden_message()
  end

  test "a clean item saves", %{conn: conn} do
    view = with_items(conn, 1)
    code = unique("N")

    save(view, code, %{"0" => %{"status" => "fine"}})

    assert [%{items: [%{status: "fine"}]}] = saved(code)
  end

  test "a sub-form under a field the page hides has its error flashed", %{conn: conn} do
    {:ok, view, html} = live(conn, "/test/hidden_address/create")
    refute html =~ "form[address]"

    html =
      view
      |> form("form[phx-submit=save]", %{"form" => %{"code" => unique("H")}})
      |> render_submit()

    assert flash(html) =~ "Address › Street: is required"
    refute flash(html) =~ ActionErrors.forbidden_message()
  end

  defp with_items(conn, count) do
    {:ok, view, _html} = live(conn, "/test/nested_items/create")
    for _ <- 1..count, do: add_form(view, "form[items]")
    view
  end

  defp add_form(view, path) do
    view
    |> element("button[phx-click=add-form][phx-value-path='#{path}']")
    |> render_click()
  end

  defp save(view, code, items) do
    view
    |> form("form[phx-submit=save]", %{"form" => %{"code" => code, "items" => items}})
    |> render_submit()
  end

  defp saved(code) do
    Example.Test.NestedItems
    |> Ash.Query.filter(code == ^code)
    |> Ash.Query.load(:items)
    |> Ash.read!(authorize?: false)
  end

  # The messages in the items' section that belong to the items themselves,
  # not to a parts section inside one.
  defp item_errors(html) do
    errors_in(html, "section:has(> button[phx-value-path='form[items]'])") -- part_errors(html)
  end

  defp part_errors(html),
    do: errors_in(html, "section:has(> button[phx-value-path='form[items][0][parts]'])")

  defp errors_in(html, section) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{section} p.text-error")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp flash(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#flash-error")
    |> LazyHTML.text()
    |> String.trim()
  end
end
