defmodule ExampleWeb.CustomFilterScenarioTest do
  @moduledoc """
  The list's Advanced filters, built in the form and applied: Starts With on
  any data layer, a timestamp typed in the zone the list shows it in, and only
  the fields the actor may see.

  `Example.Test.FilterFields` holds the rows, in ETS; Starts With on Postgres
  runs against `Example.Catalog.Product`. The tables are shared with other
  async cases, so each test matches codes it made unique.
  """
  use ExampleWeb.FeatureCase, async: true

  alias AshQuick.LiveView.CustomFilter
  alias Example.Test.FilterFields

  describe "Starts With" do
    setup %{conn: conn, admin: admin} do
      {:ok, conn: log_in(conn, admin)}
    end

    # Before, Starts With was a SQL `LIKE`, which only AshPostgres defines: on
    # ETS the read was refused and the filter dropped.
    test "keeps the rows a value starts with, outside Postgres too", %{conn: conn} do
      prefix = unique("SW")
      kept = filter_field(code: "#{prefix}-kept")
      dropped = filter_field(code: "x#{prefix}-dropped")

      view = apply_filter(conn, "/test/filter_fields", "code", "starts_with", prefix)

      cells = texts(view, "td")
      assert kept.code in cells
      refute dropped.code in cells
      refute render(view) =~ "couldn&#39;t be applied"
    end

    # A `%` or `_` was a wildcard inside `LIKE`, so "50%" also kept "500".
    test "reads % and _ in the value as themselves", %{conn: conn, admin: admin} do
      prefix = unique("Tent ")

      for name <- ["#{prefix}50% off", "#{prefix}500"], do: product(name: name, actor: admin)

      view = apply_filter(conn, "/products", "name", "starts_with", "#{prefix}50%")

      cells = texts(view, "td")
      assert "#{prefix}50% off" in cells
      refute "#{prefix}500" in cells
    end
  end

  describe "a timestamp" do
    setup %{conn: conn, admin: admin} do
      {:ok, conn: log_in(conn, admin)}
    end

    # The example shows times in UTC, so the instant held is the one typed; the
    # conversion to another zone is pinned in the library's
    # `AshQuick.LiveView.FilterDatetimeTest`.
    test "is held as a UTC instant and shown back as it was typed", %{conn: conn} do
      code = unique("TS")
      later = filter_field(code: "#{code}-later", stamped_at: ~U[2026-10-22 11:00:00.000000Z])
      earlier = filter_field(code: "#{code}-earlier", stamped_at: ~U[2026-10-22 09:00:00.000000Z])

      view = apply_filter(conn, "/test/filter_fields", "stamped_at", "gt", "2026-10-22T10:00")

      cells = texts(view, "td")
      assert later.code in cells
      refute earlier.code in cells

      %{custom_filter: filter} = :sys.get_state(view.pid).socket.assigns.params
      assert [%CustomFilter{value: "2026-10-22T10:00:00Z"}] = filter.children

      view |> element("a[title='Advanced filters']") |> render_click()
      assert attribute(view, "input[type='datetime-local']", "value") == ["2026-10-22T10:00"]
    end
  end

  describe "the fields offered" do
    test "leave out one a field policy hides from the actor", %{conn: conn, editor: editor} do
      {:ok, view, _html} =
        live(log_in(conn, editor), "/test/filter_fields?show_custom_filter=true")

      fields = texts(view, "select[name^='field_name-'] option")
      assert "Code" in fields
      refute "Salary" in fields
    end

    test "include it for an actor who may see it", %{conn: conn, admin: admin} do
      {:ok, view, _html} =
        live(log_in(conn, admin), "/test/filter_fields?show_custom_filter=true")

      assert "Salary" in texts(view, "select[name^='field_name-'] option")
    end

    # A link written for an admin, opened by someone else: the row on the
    # field they may not see is dropped before the read, which Ash would
    # otherwise answer with an empty list, and they are told.
    test "drop a row from a link that names a field the actor may not see", %{
      conn: conn,
      editor: editor
    } do
      code = unique("HF")
      row = filter_field(code: code, salary: 100)

      filter =
        encode_filter([
          %{"field_name" => "salary", "operator" => "gt", "value" => "10"},
          %{"field_name" => "code", "operator" => "equals", "value" => code}
        ])

      {:ok, view, html} =
        live(log_in(conn, editor), "/test/filter_fields?custom_filter=#{filter}")

      assert html =~ "That filter couldn&#39;t be applied to this list"
      assert row.code in texts(view, "td")

      %{custom_filter: kept} = :sys.get_state(view.pid).socket.assigns.params
      assert [%CustomFilter{field_name: "code"}] = kept.children
    end

    test "keep that row for an actor who may see the field", %{conn: conn, admin: admin} do
      code = unique("HF")
      row = filter_field(code: code, salary: 100)

      filter =
        encode_filter([
          %{"field_name" => "salary", "operator" => "gt", "value" => "10"},
          %{"field_name" => "code", "operator" => "equals", "value" => code}
        ])

      {:ok, view, html} = live(log_in(conn, admin), "/test/filter_fields?custom_filter=#{filter}")

      refute html =~ "couldn&#39;t be applied"
      assert row.code in texts(view, "td")
      %{custom_filter: kept} = :sys.get_state(view.pid).socket.assigns.params
      assert length(kept.children) == 2
    end

    # A real field the form cannot filter on, from a link written by hand: the
    # select shows it, rather than the first field offered, which the browser
    # would show and which could then not be picked.
    test "show a row's field the form does not offer as held", %{conn: conn, admin: admin} do
      filter = encode_filter([%{"field_name" => "tags", "operator" => "equals", "value" => "x"}])

      {:ok, view, _html} =
        live(
          log_in(conn, admin),
          "/test/filter_fields?show_custom_filter=true&custom_filter=#{filter}"
        )

      assert texts(view, "select[name^='field_name-'] option[disabled][selected]") == ["Tags"]
    end

    # Only from a stale page or a forged event, since the select never offers
    # the field: the row is left as it was rather than the page crashing.
    test "ignore an event picking a field the form does not offer", %{conn: conn, editor: editor} do
      {:ok, view, _html} =
        live(log_in(conn, editor), "/test/filter_fields?show_custom_filter=true")

      uuid = filter_uuid(view)
      before = attribute(view, "select[name='field_name-#{uuid}'] option[selected]", "value")

      filter_change(view, "field_name-#{uuid}", "salary")

      assert attribute(view, "select[name='field_name-#{uuid}'] option[selected]", "value") ==
               before
    end
  end

  defp encode_filter(rows) do
    %{"operator" => "and", "children" => rows}
    |> JSON.encode!()
    |> :base64.encode()
    |> URI.encode_www_form()
  end

  defp filter_field(attrs) do
    Ash.create!(FilterFields, Map.new(attrs), authorize?: false)
  end

  # Opens the filter on `path`, sets its one row and applies it.
  defp apply_filter(conn, path, field, operator, value) do
    {:ok, view, _html} = live(conn, "#{path}?show_custom_filter=true")
    uuid = filter_uuid(view)

    filter_change(view, "field_name-#{uuid}", field)
    filter_change(view, "operator-#{uuid}", operator)
    filter_change(view, "value-#{uuid}", value)
    view |> element("#custom-filter-form") |> render_submit()

    view
  end

  defp filter_uuid(view) do
    [name] = attribute(view, "select[name^='field_name-']", "name")
    String.replace_prefix(name, "field_name-", "")
  end

  defp filter_change(view, name, value) do
    view
    |> element("#custom-filter-form")
    |> render_change(%{"_target" => [name], name => value})
  end

  defp attribute(view, selector, name) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
  end

  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
