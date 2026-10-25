defmodule ExampleWeb.CustomFilterScenarioTest do
  @moduledoc """
  The list's Advanced filters, built in the form and applied: Starts With on
  any data layer, a timestamp typed in the zone the list shows it in, a value
  its field cannot take named under its row, and only the fields the actor may
  see.

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

  describe "a boolean" do
    setup %{conn: conn, admin: admin} do
      {:ok, conn: log_in(conn, admin)}
    end

    # Yes and No each keep only their own rows. A row never set is neither:
    # No compares `== false`, which a nil does not equal, so an unanswered
    # flag is not read as a no.
    test "is picked as Yes or No, and each keeps only its own rows", %{conn: conn} do
      code = unique("YN")
      yes = filter_field(code: "#{code}-yes", active: true)
      no = filter_field(code: "#{code}-no", active: false)
      unset = filter_field(code: "#{code}-unset", active: nil)

      {:ok, view, _html} = live(conn, "/test/filter_fields?show_custom_filter=true")
      uuid = filter_uuid(view)
      filter_change(view, "field_name-#{uuid}", "active")

      assert texts(view, "select[name='value-#{uuid}'] option") == ["", "Yes", "No"]

      for {value, kept, dropped} <- [{"true", yes, [no, unset]}, {"false", no, [yes, unset]}] do
        view = apply_filter(conn, "/test/filter_fields", "active", "equals", value)

        cells = texts(view, "td")
        assert kept.code in cells, "#{value} dropped #{kept.code}"
        for row <- dropped, do: refute(row.code in cells, "#{value} kept #{row.code}")
      end
    end

    # The list shows a flag the way the filter offers it.
    test "reads Yes or No in the list", %{conn: conn} do
      code = unique("YL")
      filter_field(code: "#{code}-yes", active: true)
      filter_field(code: "#{code}-no", active: false)

      {:ok, view, _html} = live(conn, "/test/filter_fields")

      rows =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("tbody tr")
        |> Enum.map(fn row ->
          row |> LazyHTML.query("td") |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
        end)

      assert Enum.any?(rows, &("#{code}-yes" in &1 and "Yes" in &1))
      assert Enum.any?(rows, &("#{code}-no" in &1 and "No" in &1))
      refute Enum.any?(rows, &("True" in &1 or "False" in &1))
    end
  end

  # Before, a value its field could not take reached the data layer, which
  # refused the whole tree: the list came back unfiltered under a flash that
  # named no row. Ash casts a filter's values by the field's type, so the form
  # asks the same question on Apply.
  describe "a value its field cannot take" do
    setup %{conn: conn, admin: admin} do
      {:ok, conn: log_in(conn, admin)}
    end

    test "is shown under its row, and nothing is applied", %{conn: conn} do
      row = filter_field(code: unique("BV"), salary: 5)

      view = apply_filter(conn, "/test/filter_fields", "salary", "gt", "ten")
      uuid = filter_uuid(view)

      assert texts(view, "#value-error-#{uuid}") == ["is invalid"]
      assert attribute(view, "input[name='value-#{uuid}']", "aria-invalid") == ["true"]

      assert attribute(view, "input[name='value-#{uuid}']", "aria-describedby") ==
               ["value-error-#{uuid}"]

      refute_patched(view)
      assert row.code in texts(view, "td")
      refute render(view) =~ "couldn&#39;t be applied"
      assert has_element?(view, "#custom-filter-form")
    end

    test "names only the row that holds it", %{conn: conn} do
      row = filter_field(code: unique("BV"), salary: 5)

      {:ok, view, _html} = live(conn, "/test/filter_fields?show_custom_filter=true")
      code_row = filter_uuid(view)
      filter_change(view, "field_name-#{code_row}", "code")
      filter_change(view, "value-#{code_row}", "anything")

      view |> element("button[phx-value-nested='false']") |> render_click()
      salary_row = view |> filter_uuids() |> List.last()
      filter_change(view, "field_name-#{salary_row}", "salary")
      filter_change(view, "operator-#{salary_row}", "gt")
      filter_change(view, "value-#{salary_row}", "1.5")
      view |> element("#custom-filter-form") |> render_submit()

      assert texts(view, "#value-error-#{salary_row}") == ["is invalid"]
      refute has_element?(view, "#value-error-#{code_row}")
      refute_patched(view)
      assert row.code in texts(view, "td")
    end

    test "is forgotten once the row is edited, and a good value applies", %{conn: conn} do
      code = unique("BV")
      kept = filter_field(code: "#{code}-kept", salary: 100)
      dropped = filter_field(code: "#{code}-dropped", salary: 5)

      view = apply_filter(conn, "/test/filter_fields", "salary", "gt", "ten")
      uuid = filter_uuid(view)
      assert has_element?(view, "#value-error-#{uuid}")

      filter_change(view, "value-#{uuid}", "10")
      refute has_element?(view, "#value-error-#{uuid}")

      view |> element("#custom-filter-form") |> render_submit()

      cells = texts(view, "td")
      assert kept.code in cells
      refute dropped.code in cells
    end

    # The picked value of a select is checked too, though only a forged event
    # can send a bad one, and the select says so as a text input would.
    test "marks a select holding one as invalid", %{conn: conn} do
      view = apply_filter(conn, "/test/filter_fields", "active", "equals", "maybe")
      uuid = filter_uuid(view)

      assert texts(view, "#value-error-#{uuid}") == ["is invalid"]
      assert attribute(view, "select[name='value-#{uuid}']", "aria-invalid") == ["true"]
      refute_patched(view)
    end

    # Ash's filter reads a typed atom as the string it was typed as, whether
    # or not the VM has that atom, so the form does not refuse it either.
    test "lets an atom through that the VM does not know", %{conn: conn} do
      value = "unknown_state_#{System.unique_integer([:positive])}"

      view = apply_filter(conn, "/test/filter_fields", "state", "equals", value)

      refute has_element?(view, "[id^='value-error-']")
      assert_patch(view)
    end

    # On Postgres, where the data layer's own cast used to be the one refusing.
    test "catches a broken UUID and text in a number", %{conn: conn, admin: admin} do
      name = unique("Tent ")
      product(name: name, actor: admin)

      for {field, operator, value} <- [{"id", "equals", "not-a-uuid"}, {"price", "gt", "cheap"}] do
        view = apply_filter(conn, "/products", field, operator, value)

        assert texts(view, "#value-error-#{filter_uuid(view)}") == ["is invalid"],
               "#{field} took #{value}"

        refute_patched(view)
        assert name in texts(view, "td")
      end
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

  # Like every modal, the filter closes only by its ✕ or its Cancel: a tap
  # beside it, easy on a phone, would throw away a filter half built.
  describe "the modal" do
    @modal "#ash-quick-filter-modal"

    setup %{conn: conn, admin: admin} do
      {:ok, conn: log_in(conn, admin)}
    end

    test "has no backdrop to click away", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/filter_fields?show_custom_filter=true")

      assert has_element?(view, @modal)
      refute has_element?(view, "#{@modal} .modal-backdrop")
      # Named by its heading, so a screen reader announces "Custom Filter".
      assert has_element?(view, "#{@modal}[aria-labelledby='ash-quick-filter-modal-title']")
      assert has_element?(view, "#ash-quick-filter-modal-title", "Custom Filter")
    end

    test "closes by its ✕", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/filter_fields?show_custom_filter=true")

      view |> element("#{@modal} a[aria-label=Close]") |> render_click()

      assert_patch(view, "/test/filter_fields")
      refute has_element?(view, @modal)
    end

    # The edit made in the modal is dropped; the filter applied before stays,
    # both on the list and in the modal opened again.
    test "closes by Cancel, leaving the applied filter as it was", %{conn: conn} do
      code = unique("CF")
      kept = filter_field(code: code)
      other = filter_field(code: "#{code}-other")
      filter = encode_filter([%{"field_name" => "code", "operator" => "equals", "value" => code}])

      {:ok, view, _html} =
        live(conn, "/test/filter_fields?show_custom_filter=true&custom_filter=#{filter}")

      uuid = filter_uuid(view)
      filter_change(view, "value-#{uuid}", "#{code}-edited")
      view |> element("#{@modal} form button[type=button]", "Cancel") |> render_click()

      refute has_element?(view, @modal)
      cells = texts(view, "td")
      assert kept.code in cells
      refute other.code in cells

      view |> element("a[title='Advanced filters']") |> render_click()
      assert attribute(view, "input[name='value-#{filter_uuid(view)}']", "value") == [code]
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
    [uuid] = filter_uuids(view)
    uuid
  end

  defp filter_uuids(view) do
    view
    |> attribute("select[name^='field_name-']", "name")
    |> Enum.map(&String.replace_prefix(&1, "field_name-", ""))
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
