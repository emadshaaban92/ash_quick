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

    # Both ways out wait on the submit: Cancel is a button in the form, which
    # LiveView disables, and the live ✕ hides for its disabled twin while a
    # form in the box loads. That swap is a CSS variant LiveViewTest cannot
    # trigger, so this pins what it hangs on: the box is the `group/modal`
    # the variant names, the form is inside it, and the live ✕ carries it.
    test "leaves neither way out live while Apply runs", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/filter_fields?show_custom_filter=true")
      box = ~s(#{@modal} [class~="group/modal"])

      assert has_element?(view, "#{box} #custom-filter-form button[type=button]", "Cancel")

      assert has_element?(
               view,
               ~s(#{box} a[aria-label=Close][class~="group-has-[form.phx-submit-loading]/modal:hidden"])
             )

      assert has_element?(view, "#{box} button[disabled][aria-label=Close]")
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

  # Before, a filtered list looked like the whole one: nothing on it said a
  # filter was on, and the only way to see or drop one was the modal.
  describe "the applied filter" do
    setup %{conn: conn, admin: admin} do
      {:ok, conn: log_in(conn, admin)}
    end

    test "shows each row as a chip, and their count on the button", %{conn: conn} do
      code = unique("CH")
      filter_field(code: code, active: true)

      filter =
        encode_filter([
          %{"field_name" => "code", "operator" => "starts_with", "value" => code},
          %{"field_name" => "active", "operator" => "equals", "value" => "true"}
        ])

      {:ok, view, _html} = live(conn, "/test/filter_fields?custom_filter=#{filter}")

      assert chips(view) == ["Code starts with #{code}", "Active = Yes"]
      assert has_element?(view, "#ash-quick-filter-count", "2 filters applied")
      # The count's own words would otherwise name the link, so its name
      # stays first.
      assert has_element?(view, "a[title='Advanced filters'] > .sr-only", "Advanced filters")
    end

    # A timestamp is held as a UTC instant; the chip shows it the way the list
    # shows one, in the list's zone, not as the `Z` string in the URL. The
    # field is named as its column is, not as the form humanizes it.
    test "reads a timestamp as the list shows one, under its column's name", %{conn: conn} do
      filter =
        encode_filter([
          %{"field_name" => "stamped_at", "operator" => "gt", "value" => "2026-10-22T10:00:00Z"}
        ])

      {:ok, view, _html} = live(conn, "/test/filter_fields?custom_filter=#{filter}")

      shown = AshQuick.Config.format_datetime(~U[2026-10-22 10:00:00Z])
      assert chips(view) == ["Stamped > #{shown}"]

      # The modal the chips open calls the field the same.
      view |> element("a[title='Advanced filters']") |> render_click()
      assert texts(view, "select[name^='field_name-'] option[selected]") == ["Stamped"]
    end

    test "drops a row by its chip's ✕, and the list widens", %{conn: conn} do
      code = unique("CX")
      yes = filter_field(code: "#{code}-yes", active: true)
      no = filter_field(code: "#{code}-no", active: false)

      filter =
        encode_filter([
          %{"field_name" => "code", "operator" => "starts_with", "value" => code},
          %{"field_name" => "active", "operator" => "equals", "value" => "true"}
        ])

      {:ok, view, _html} = live(conn, "/test/filter_fields?custom_filter=#{filter}")
      refute no.code in texts(view, "td")

      view
      |> element(~s([data-filter-chip="active"] a[data-remove-filter]))
      |> render_click()

      cells = texts(view, "td")
      assert yes.code in cells
      assert no.code in cells
      assert chips(view) == ["Code starts with #{code}"]
      assert has_element?(view, "#ash-quick-filter-count", "1 filter applied")
    end

    test "leaves no filter once its last chip goes", %{conn: conn} do
      filter = encode_filter([%{"field_name" => "code", "operator" => "equals", "value" => "x"}])
      {:ok, view, _html} = live(conn, "/test/filter_fields?custom_filter=#{filter}")

      view
      |> element(~s([data-filter-chip="code"] a[data-remove-filter]))
      |> render_click()

      assert_patch(view, "/test/filter_fields")
      assert chips(view) == []
      refute has_element?(view, "#ash-quick-filter-count")
    end

    test "is dropped whole by Clear all", %{conn: conn} do
      filter =
        encode_filter([
          %{"field_name" => "code", "operator" => "equals", "value" => "x"},
          %{"field_name" => "active", "operator" => "equals", "value" => "true"}
        ])

      {:ok, view, _html} = live(conn, "/test/filter_fields?custom_filter=#{filter}")

      view |> element("#ash-quick-filter-clear") |> render_click()

      assert_patch(view, "/test/filter_fields")
      assert chips(view) == []
    end

    # A group's rows mean something only together, so it is one chip, which
    # opens the modal to read it. Its rows still count on the button.
    test "shows a group as one chip that opens the modal", %{conn: conn} do
      filter =
        encode_filter([
          %{"field_name" => "code", "operator" => "equals", "value" => "x"},
          %{
            "operator" => "or",
            "children" => [
              %{"field_name" => "active", "operator" => "equals", "value" => "true"},
              %{"field_name" => "code", "operator" => "equals", "value" => "y"}
            ]
          }
        ])

      {:ok, view, _html} = live(conn, "/test/filter_fields?custom_filter=#{filter}")

      # The group is an `or`, so either of its rows is enough.
      assert chips(view) == ["Code = x", "Any of 2 conditions"]
      assert has_element?(view, "#ash-quick-filter-count", "3 filters applied")

      view |> element(~s([data-filter-chip="group"] a), "2 conditions") |> render_click()
      assert has_element?(view, "#ash-quick-filter-modal")
    end

    test "says a group needs all of its rows when it does", %{conn: conn} do
      filter =
        encode_filter([
          %{
            "operator" => "and",
            "children" => [
              %{"field_name" => "active", "operator" => "equals", "value" => "true"},
              %{"field_name" => "code", "operator" => "equals", "value" => "y"}
            ]
          }
        ])

      {:ok, view, _html} = live(conn, "/test/filter_fields?custom_filter=#{filter}")

      assert chips(view) == ["All of 2 conditions"]
    end

    # A group of one row means that row, so it reads as one; its ✕ takes the
    # group, which leaves no empty group behind in the filter.
    test "shows a group of one row as that row, and drops the group by its ✕", %{conn: conn} do
      code = unique("G1")
      yes = filter_field(code: "#{code}-yes", active: true)
      no = filter_field(code: "#{code}-no", active: false)

      filter =
        encode_filter([
          %{"field_name" => "code", "operator" => "starts_with", "value" => code},
          %{
            "operator" => "or",
            "children" => [%{"field_name" => "active", "operator" => "equals", "value" => "true"}]
          }
        ])

      {:ok, view, _html} = live(conn, "/test/filter_fields?custom_filter=#{filter}")

      assert chips(view) == ["Code starts with #{code}", "Active = Yes"]
      refute no.code in texts(view, "td")

      view |> element(~s([data-filter-chip="active"] a[data-remove-filter])) |> render_click()

      assert chips(view) == ["Code starts with #{code}"]
      cells = texts(view, "td")
      assert yes.code in cells
      assert no.code in cells
      assert has_element?(view, "#ash-quick-filter-count", "1 filter applied")
    end

    # A link written by hand can make the whole filter one row, with no group.
    test "shows a root that is a row, and leaves no filter by its ✕", %{conn: conn} do
      filter =
        %{"field_name" => "code", "operator" => "equals", "value" => "x"}
        |> JSON.encode!()
        |> :base64.encode()
        |> URI.encode_www_form()

      {:ok, view, _html} = live(conn, "/test/filter_fields?custom_filter=#{filter}")

      assert chips(view) == ["Code = x"]
      assert has_element?(view, "#ash-quick-filter-count", "1 filter applied")

      view |> element(~s([data-filter-chip="code"] a[data-remove-filter])) |> render_click()

      assert_patch(view, "/test/filter_fields")
      assert chips(view) == []
    end

    # Each ✕ is named by its chip, so a screen reader can tell them apart.
    test "names each ✕ by its chip", %{conn: conn} do
      filter =
        encode_filter([
          %{"field_name" => "code", "operator" => "equals", "value" => "x"},
          %{"field_name" => "active", "operator" => "equals", "value" => "true"}
        ])

      {:ok, view, _html} = live(conn, "/test/filter_fields?custom_filter=#{filter}")

      names =
        for ids <- attribute(view, "[data-filter-chip] a[data-remove-filter]", "aria-labelledby") do
          ids
          |> String.split()
          |> Enum.map_join(" ", &(view |> texts("##{&1}") |> Enum.join()))
          |> String.replace(~r/\s+/, " ")
        end

      assert names == ["Remove filter Code = x", "Remove filter Active = Yes"]
      # The words that name a ✕ are read only as its name, not again beside it.
      assert has_element?(view, "[data-filter-chip] span[hidden]", "Remove filter")
    end

    # A link can hand Any Of to a field the form offers it on only for a fixed
    # set. Its values read one by one as the field renders them, rather than
    # rendering a list as iodata, which raised and took the page down.
    test "shows a list value from a link, each as its field renders one", %{conn: conn} do
      code = unique("IN")
      row = filter_field(code: code, salary: 1000)

      filter =
        encode_filter([
          %{"field_name" => "code", "operator" => "equals", "value" => code},
          %{"field_name" => "salary", "operator" => "in", "value" => [1000, 2000]}
        ])

      {:ok, view, _html} = live(conn, "/test/filter_fields?custom_filter=#{filter}")

      assert row.code in texts(view, "td")
      assert chips(view) == ["Code = #{code}", "Salary is any of 1000, 2000"]
    end

    test "says when any one row is enough", %{conn: conn} do
      filter =
        encode_filter(
          [
            %{"field_name" => "code", "operator" => "equals", "value" => "x"},
            %{"field_name" => "code", "operator" => "equals", "value" => "y"}
          ],
          "or"
        )

      {:ok, view, _html} = live(conn, "/test/filter_fields?custom_filter=#{filter}")

      assert has_element?(view, "#ash-quick-filter-chips", "Any of:")
    end

    # A row left without a value filters by nothing, so it has no chip.
    test "has no chip for a row without a value", %{conn: conn} do
      filter = encode_filter([%{"field_name" => "code", "operator" => "equals", "value" => ""}])
      {:ok, view, _html} = live(conn, "/test/filter_fields?custom_filter=#{filter}")

      assert chips(view) == []
      refute has_element?(view, "#ash-quick-filter-count")
    end

    # The row on the field the editor may not see is dropped before the read,
    # so the chips show only what the list was filtered by.
    test "has no chip for a row dropped before the read", %{conn: conn, editor: editor} do
      filter =
        encode_filter([
          %{"field_name" => "salary", "operator" => "gt", "value" => "10"},
          %{"field_name" => "code", "operator" => "equals", "value" => "x"}
        ])

      {:ok, view, _html} =
        live(log_in(conn, editor), "/test/filter_fields?custom_filter=#{filter}")

      assert chips(view) == ["Code = x"]
    end
  end

  describe "Ends With and Not Contains" do
    setup %{conn: conn, admin: admin} do
      {:ok, conn: log_in(conn, admin)}
    end

    test "keep the rows a value ends with, outside Postgres too", %{conn: conn} do
      code = unique("EW")
      kept = filter_field(code: "#{code}-kept-end")
      dropped = filter_field(code: "#{code}-end-dropped")

      view = apply_filter(conn, "/test/filter_fields", "code", "ends_with", "#{code}-kept-end")

      cells = texts(view, "td")
      assert kept.code in cells
      refute dropped.code in cells
      assert chips(view) == ["Code ends with #{code}-kept-end"]
    end

    test "read % and _ as themselves on Postgres", %{conn: conn, admin: admin} do
      suffix = unique(" 50%")
      kept = "Tent#{suffix}"
      dropped = "Tent#{String.replace(suffix, "%", "0")}"

      for name <- [kept, dropped], do: product(name: name, actor: admin)

      view = apply_filter(conn, "/products", "name", "ends_with", suffix)
      cells = texts(view, "td")
      assert kept in cells
      refute dropped in cells

      view = apply_filter(conn, "/products", "name", "not_contains", "%")
      cells = texts(view, "td")
      assert dropped in cells
      refute kept in cells
    end

    # A note left empty holds no text at all, so Ash reads "does not contain"
    # of it as unknown, the way != leaves it out: Is Empty is what finds it.
    test "drop the rows that hold the value, and an empty one", %{conn: conn} do
      code = unique("NC")
      kept = filter_field(code: "#{code}-kept", note: "plain")
      dropped = filter_field(code: "#{code}-dropped", note: "has #{code} in it")
      empty = filter_field(code: "#{code}-empty", note: nil)

      view = apply_filter(conn, "/test/filter_fields", "note", "not_contains", code)

      cells = texts(view, "td")
      assert kept.code in cells
      refute dropped.code in cells
      refute empty.code in cells
      assert chips(view) == ["Note does not contain #{code}"]
    end
  end

  describe "Is Empty and Is Not Empty" do
    setup %{conn: conn, admin: admin} do
      {:ok, conn: log_in(conn, admin)}
    end

    test "split the rows by whether a field holds anything", %{conn: conn} do
      code = unique("IE")
      noted = filter_field(code: "#{code}-noted", note: "something")
      empty = filter_field(code: "#{code}-empty", note: nil)

      for {operator, kept, dropped, chip} <- [
            {"is_nil", empty, noted, "Note is empty"},
            {"is_not_nil", noted, empty, "Note is not empty"}
          ] do
        {:ok, view, _html} = live(conn, "/test/filter_fields?show_custom_filter=true")
        uuid = filter_uuid(view)
        filter_change(view, "field_name-#{uuid}", "note")
        filter_change(view, "operator-#{uuid}", operator)

        refute has_element?(view, "[name^='value-#{uuid}']")

        view |> element("#custom-filter-form") |> render_submit()

        cells = texts(view, "td")
        assert kept.code in cells, "#{operator} dropped #{kept.code}"
        refute dropped.code in cells, "#{operator} kept #{dropped.code}"
        assert chips(view) == [chip]
      end
    end

    # A string kept as typed can hold `""`, which the list shows as blank as a
    # `nil`, so both read as empty.
    test "count a blank string as empty", %{conn: conn} do
      code = unique("IB")
      blank = filter_field(code: "#{code}-blank", note: "")
      unset = filter_field(code: "#{code}-unset", note: nil)
      noted = filter_field(code: "#{code}-noted", note: "something")

      view = apply_filter(conn, "/test/filter_fields", "note", "is_nil", "")
      cells = texts(view, "td")
      assert blank.code in cells
      assert unset.code in cells
      refute noted.code in cells

      view = apply_filter(conn, "/test/filter_fields", "note", "is_not_nil", "")
      cells = texts(view, "td")
      assert noted.code in cells
      refute blank.code in cells
      refute unset.code in cells
    end

    # Ash reads a memo the editor may not see as `nil`, so Is Empty would keep
    # every inactive row as one without a memo.
    test "are not offered on a field the actor sees on some rows only", %{
      conn: conn,
      admin: admin,
      editor: editor
    } do
      for {actor, offered?} <- [{editor, false}, {admin, true}] do
        {:ok, view, _html} =
          live(log_in(conn, actor), "/test/filter_fields?show_custom_filter=true")

        uuid = filter_uuid(view)
        filter_change(view, "field_name-#{uuid}", "memo")
        options = texts(view, "select[name='operator-#{uuid}'] option")

        assert "Contains" in options
        assert "Is Empty" in options == offered?, "#{actor.role}: #{inspect(options)}"
      end
    end

    test "drop such a row from a link, with the refused-filter flash", %{
      conn: conn,
      editor: editor
    } do
      code = unique("IH")
      hidden = filter_field(code: "#{code}-hidden", memo: "secret", active: false)

      filter =
        encode_filter([
          %{"field_name" => "memo", "operator" => "is_nil"},
          %{"field_name" => "code", "operator" => "starts_with", "value" => code}
        ])

      {:ok, view, _html} =
        live(log_in(conn, editor), "/test/filter_fields?custom_filter=#{filter}")

      assert render(view) =~ "couldn&#39;t be applied"
      assert chips(view) == ["Code starts with #{code}"]
      assert hidden.code in texts(view, "td")
    end

    # A sum with a default is never empty, so neither would narrow the list.
    test "are not offered on an aggregate with a default", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/filter_fields?show_custom_filter=true")
      uuid = filter_uuid(view)

      filter_change(view, "field_name-#{uuid}", "children_salary")

      refute "Is Empty" in texts(view, "select[name='operator-#{uuid}'] option")
    end

    # A required field always holds something, so neither is offered on it.
    test "are offered only on a field that can be empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/filter_fields?show_custom_filter=true")
      uuid = filter_uuid(view)

      filter_change(view, "field_name-#{uuid}", "code")
      refute texts(view, "select[name='operator-#{uuid}'] option") |> Enum.member?("Is Empty")

      filter_change(view, "field_name-#{uuid}", "active")

      assert texts(view, "select[name='operator-#{uuid}'] option") ==
               ["=", "!=", "Is Empty", "Is Not Empty"]
    end
  end

  describe "Any Of" do
    setup %{conn: conn, admin: admin} do
      {:ok, conn: log_in(conn, admin)}
    end

    test "keeps the rows holding any value picked from a fixed set", %{conn: conn} do
      code = unique("AO")
      draft = filter_field(code: "#{code}-draft", stage: :draft)
      live_row = filter_field(code: "#{code}-live", stage: :live)
      archived = filter_field(code: "#{code}-archived", stage: :archived)

      {:ok, view, _html} = live(conn, "/test/filter_fields?show_custom_filter=true")
      uuid = filter_uuid(view)
      filter_change(view, "field_name-#{uuid}", "stage")
      filter_change(view, "operator-#{uuid}", "in")

      assert texts(view, "select[name='value-#{uuid}[]'][multiple] option") ==
               ["Draft", "Live", "Archived"]

      filter_change(view, "value-#{uuid}", ["draft", "archived"])
      view |> element("#custom-filter-form") |> render_submit()

      cells = texts(view, "td")
      assert draft.code in cells
      assert archived.code in cells
      refute live_row.code in cells
      assert chips(view) == ["Stage is any of Draft, Archived"]
    end

    # A link can name Any Of on a field without a fixed set. The form shows
    # its values typed in, one after another, rather than crashing on a list
    # in a text input, and splits them again at each comma.
    test "from a link on a field without a fixed set is typed in", %{conn: conn} do
      code = unique("AT")
      kept = filter_field(code: "#{code}-kept", salary: 3000)
      dropped = filter_field(code: "#{code}-dropped", salary: 1000)

      filter =
        encode_filter([
          %{"field_name" => "code", "operator" => "starts_with", "value" => code},
          %{"field_name" => "salary", "operator" => "in", "value" => [1000, 2000]}
        ])

      {:ok, view, _html} =
        live(conn, "/test/filter_fields?custom_filter=#{filter}&show_custom_filter=true")

      [_code, uuid] = filter_uuids(view)
      assert attribute(view, "input[name='value-#{uuid}']", "value") == ["1000, 2000"]
      assert texts(view, "select[name='operator-#{uuid}'] option[selected]") == ["Any Of"]

      filter_change(view, "value-#{uuid}", "2000, 3000")
      view |> element("#custom-filter-form") |> render_submit()

      cells = texts(view, "td")
      assert kept.code in cells
      refute dropped.code in cells
      assert chips(view) == ["Code starts with #{code}", "Salary is any of 2000, 3000"]
    end

    # Picking Any Of after = keeps the value picked as the list's one value,
    # and going back keeps the first value of the list.
    test "carries the value across from =, and back", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/filter_fields?show_custom_filter=true")
      uuid = filter_uuid(view)
      filter_change(view, "field_name-#{uuid}", "stage")
      filter_change(view, "value-#{uuid}", "live")
      filter_change(view, "operator-#{uuid}", "in")

      assert texts(view, "select[name='value-#{uuid}[]'] option[selected]") == ["Live"]

      filter_change(view, "value-#{uuid}", ["archived", "draft"])
      filter_change(view, "operator-#{uuid}", "equals")

      assert texts(view, "select[name='value-#{uuid}'] option[selected]") == ["Archived"]
    end

    # A select with nothing picked sends nothing, so the row filters by nothing.
    test "applies nothing once every value is unpicked", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/filter_fields?show_custom_filter=true")
      uuid = filter_uuid(view)
      filter_change(view, "field_name-#{uuid}", "stage")
      filter_change(view, "operator-#{uuid}", "in")
      filter_change(view, "value-#{uuid}", ["live"])

      # A browser sends nothing for a select none of whose options is picked.
      filter_change(view, "value-#{uuid}", [])

      view |> element("#custom-filter-form") |> render_submit()

      assert chips(view) == []
      refute has_element?(view, "#ash-quick-filter-count")
    end
  end

  describe "On Day" do
    setup %{conn: conn, admin: admin} do
      {:ok, conn: log_in(conn, admin)}
    end

    # The example shows times in UTC; the day read in another zone is pinned
    # in the library's `AshQuick.LiveView.FilterDatetimeTest`.
    test "keeps the rows stamped on that day, from its first moment to its last", %{
      conn: conn
    } do
      code = unique("OD")
      before = filter_field(code: "#{code}-before", stamped_at: ~U[2026-10-21 23:59:59.999999Z])
      first = filter_field(code: "#{code}-first", stamped_at: ~U[2026-10-22 00:00:00.000000Z])
      last = filter_field(code: "#{code}-last", stamped_at: ~U[2026-10-22 23:59:59.999999Z])
      next = filter_field(code: "#{code}-next", stamped_at: ~U[2026-10-23 00:00:00.000000Z])

      view = apply_filter(conn, "/test/filter_fields", "stamped_at", "on", "2026-10-22")

      cells = texts(view, "td")
      assert first.code in cells
      assert last.code in cells
      refute before.code in cells
      refute next.code in cells
      assert chips(view) == ["Stamped on #{AshQuick.Config.format_date(~D[2026-10-22])}"]

      view |> element("a[title='Advanced filters']") |> render_click()
      assert attribute(view, "input[type='date'][name^='value-']", "value") == ["2026-10-22"]
    end

    # Dropped before the read, rather than matching one instant of the day,
    # so the read never sees it and nothing is logged as having failed.
    test "drops a link's value that is no date, with the refused-filter flash", %{conn: conn} do
      filter =
        encode_filter([
          %{"field_name" => "stamped_at", "operator" => "on", "value" => "2026-10-22T10:00:00"}
        ])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, view, _html} = live(conn, "/test/filter_fields?custom_filter=#{filter}")

          assert render(view) =~ "couldn&#39;t be applied"
          assert chips(view) == []
        end)

      # Refuted by this page's own resource, because `capture_log/1` also
      # catches the re-reads the rest of the async suite logs meanwhile.
      refute log =~ "re-reading #{inspect(Example.Test.FilterFields)}"
    end

    # A link can write a row as `children: []`; it is a row all the same, so
    # its instant does not follow it to On Day, which takes a date.
    test "clears a link row's instant when it moves to On Day", %{conn: conn} do
      filter =
        encode_filter([
          %{
            "field_name" => "stamped_at",
            "operator" => "gt",
            "value" => "2026-10-22T08:00:00Z",
            "children" => []
          }
        ])

      {:ok, view, _html} =
        live(conn, "/test/filter_fields?custom_filter=#{filter}&show_custom_filter=true")

      uuid = filter_uuid(view)
      filter_change(view, "operator-#{uuid}", "on")

      assert attribute(view, "input[type='date'][name='value-#{uuid}']", "value") == [""]
    end

    test "names a date that is no day under its row", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/filter_fields?show_custom_filter=true")
      uuid = filter_uuid(view)
      filter_change(view, "field_name-#{uuid}", "stamped_at")
      filter_change(view, "operator-#{uuid}", "on")
      filter_change(view, "value-#{uuid}", "2026-13-45")
      view |> element("#custom-filter-form") |> render_submit()

      assert has_element?(view, "#value-error-#{uuid}")
      assert chips(view) == []
    end
  end

  defp encode_filter(rows, operator \\ "and") do
    %{"operator" => operator, "children" => rows}
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

  # Each chip's words, spaces collapsed, without its ✕.
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
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
