defmodule ExampleWeb.CustomFilterGuardScenarioTest do
  @moduledoc """
  What a list holds a custom filter to, from a link or the form: its size,
  the operators its fields take, a read too slow to answer, a row with no
  value, a number typed in Arabic digits, and a field typed with a NewType.

  `Example.Test.FilterFields` holds the rows, in ETS; the stored-map and
  NewType rows run against Postgres. The tables are shared with other async
  cases, so each test matches values it made unique.
  """
  use ExampleWeb.FeatureCase, async: true

  import ExUnit.CaptureLog

  alias AshQuick.LiveView.CustomFilter
  alias Example.Test.FilterFields

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  @refused "couldn&#39;t be applied"

  describe "a filter's size" do
    test "is read up to its bounds", %{conn: conn} do
      %{rows: rows} = CustomFilter.bounds()
      code = unique("B")
      kept = filter_field(code: code)

      filter = encode_filter(for _ <- 1..rows, do: row("code", "equals", code))
      {:ok, view, html} = live(conn, "/test/filter_fields?custom_filter=#{filter}")

      refute html =~ @refused
      assert texts(view, "td") |> Enum.member?(kept.code)
      assert length(chips(view)) == rows
    end

    # Each chip drew a link holding the rest of the filter, so the page grew
    # with the square of its rows, and any visitor could send one over the
    # live socket.
    test "past its bounds, is refused whole, with the refused-filter flash", %{conn: conn} do
      %{rows: rows} = CustomFilter.bounds()
      code = unique("B")
      filter_field(code: code)
      other = filter_field(code: unique("B"))

      filter = encode_filter(for _ <- 0..rows, do: row("code", "equals", code))
      {:ok, view, html} = live(conn, "/test/filter_fields?custom_filter=#{filter}")

      assert html =~ @refused
      assert chips(view) == []
      assert other.code in texts(view, "td")
    end

    test "draws no copy of the filter in its chips", %{conn: conn} do
      filter = encode_filter(for i <- 1..10, do: row("code", "equals", "x#{i}"))
      {:ok, view, _html} = live(conn, "/test/filter_fields?custom_filter=#{filter}")

      [chips_html] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#ash-quick-filter-chips")
        |> Enum.map(&LazyHTML.to_html/1)

      assert length(chips(view)) == 10
      refute chips_html =~ "custom_filter"
    end

    test "is refused in the form past its bounds, which applies nothing", %{conn: conn} do
      %{rows: rows} = CustomFilter.bounds()
      {:ok, view, _html} = live(conn, "/test/filter_fields?show_custom_filter=true")

      for _ <- 1..rows do
        view
        |> element(~s(#custom-filter-form button[phx-value-nested="false"]))
        |> render_click()
      end

      for uuid <- filter_uuids(view) do
        filter_change(view, "field_name-#{uuid}", "code")
        filter_change(view, "operator-#{uuid}", "equals")
        filter_change(view, "value-#{uuid}", "x")
      end

      html = view |> element("#custom-filter-form") |> render_submit()

      assert html =~ "That filter is too large to apply."
      assert has_element?(view, "#custom-filter-too-large[role=alert]")
      assert has_element?(view, "#ash-quick-filter-modal")
      assert chips(view) == []
    end
  end

  # Ash's filter input takes any of its operators on any field, so a link
  # could ask what the form never writes.
  describe "a row's operator" do
    test "from a link, is refused where its field offers none such", %{conn: conn} do
      for {field, operator, value} <- [
            {"active", "gt", "true"},
            {"code", "on", "2026-01-01"},
            {"code", "gt", "M"},
            {"salary", "contains", "1"},
            {"stamped_at", "contains", "2026"},
            {"id", "starts_with", "0"}
          ] do
        filter = encode_filter([row(field, operator, value)])
        {:ok, view, html} = live(conn, "/test/filter_fields?custom_filter=#{filter}")

        assert html =~ @refused, "#{field} #{operator} was read"
        assert chips(view) == []
      end
    end

    test "from a link, is read where its field offers it", %{conn: conn} do
      code = unique("Op")
      kept = filter_field(code: "#{code}-a", salary: 7)
      also = filter_field(code: "#{code}-b", salary: 9)

      for rows <- [
            [row("code", "starts_with", code), row("salary", "lt", "8")],
            [row("code", "starts_with", code), row("salary", "is_not_nil", nil)],
            # Any Of on any field compared by Equals, as the form shows it.
            [row("code", "in", [kept.code, also.code])]
          ] do
        {:ok, view, html} =
          live(conn, "/test/filter_fields?custom_filter=#{encode_filter(rows)}")

        refute html =~ @refused
        assert kept.code in texts(view, "td")
      end
    end
  end

  describe "Apply" do
    # An untouched form wrote a filter by nothing into the URL: no chip, no
    # count, and a link that read as filtered.
    test "with no row holding a value, applies no filter and closes the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/filter_fields?show_custom_filter=true")

      view |> element("#custom-filter-form") |> render_submit()
      render(view)

      assert assert_patch(view) == "/test/filter_fields"
      refute has_element?(view, "#ash-quick-filter-modal")
      assert chips(view) == []
    end

    test "leaves the rows holding no value out of the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/filter_fields?show_custom_filter=true")

      view
      |> element(~s(#custom-filter-form button[phx-value-nested="false"]))
      |> render_click()

      [first, _second] = filter_uuids(view)
      filter_change(view, "field_name-#{first}", "code")
      filter_change(view, "operator-#{first}", "equals")
      filter_change(view, "value-#{first}", "x")

      view |> element("#custom-filter-form") |> render_submit()

      # As the URL holds it, not as a filter is read from it, which drops a
      # blank row itself.
      assert %{"children" => [%{"field_name" => "code", "operator" => "equals", "value" => "x"}]} =
               url_filter(view)
    end
  end

  describe "a number typed in" do
    test "in Arabic-Indic digits is read as the number they write", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/filter_fields?show_custom_filter=true")
      [uuid] = filter_uuids(view)

      filter_change(view, "field_name-#{uuid}", "salary")
      filter_change(view, "operator-#{uuid}", "equals")
      filter_change(view, "value-#{uuid}", "١٢٣")
      view |> element("#custom-filter-form") |> render_submit()

      # ETS compares the text a link holds with the number by type, so the
      # rows are not read here: the URL and the chip say what was applied.
      assert applied(view) == [{"salary", "equals", "123"}]
      assert chips(view) == ["Salary = 123"]
    end

    # Any Of's values typed one after another, split at the Arabic comma too.
    test "as Any Of, split at an Arabic comma", %{conn: conn} do
      code = unique("Num")
      filter = encode_filter([row("code", "in", [code])])

      {:ok, view, _html} =
        live(conn, "/test/filter_fields?show_custom_filter=true&custom_filter=#{filter}")

      [uuid] = filter_uuids(view)

      filter_change(view, "field_name-#{uuid}", "salary")
      filter_change(view, "operator-#{uuid}", "in")
      filter_change(view, "value-#{uuid}", "١٢، ٣٤")
      view |> element("#custom-filter-form") |> render_submit()

      assert applied(view) == [{"salary", "in", ["12", "34"]}]
    end

    test "with a decimal comma, where the field takes a fraction", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/filter_fields?show_custom_filter=true")
      [uuid] = filter_uuids(view)

      filter_change(view, "field_name-#{uuid}", "rate")
      filter_change(view, "operator-#{uuid}", "gt")
      filter_change(view, "value-#{uuid}", "1,5")
      view |> element("#custom-filter-form") |> render_submit()

      assert applied(view) == [{"rate", "gt", "1.5"}]
    end

    # An amount is read the same way, as is one typed with its currency.
    test "as a Money amount, in Arabic-Indic digits", %{conn: conn} do
      amount = System.unique_integer([:positive]) + 1_000_000
      above = filter_field(code: unique("FEE"), fee: Money.new(:USD, amount + 1))
      below = filter_field(code: unique("FEE"), fee: Money.new(:USD, amount - 1))

      {:ok, view, _html} = live(conn, "/test/filter_fields?show_custom_filter=true")
      [uuid] = filter_uuids(view)

      filter_change(view, "field_name-#{uuid}", "fee")
      filter_change(view, "operator-#{uuid}", "gt")
      html = filter_change(view, "value-#{uuid}", arabic_digits(amount))
      refute html =~ "is invalid"
      view |> element("#custom-filter-form") |> render_submit()

      assert applied(view) == [{"fee", "gt", "USD #{amount}"}]
      cells = texts(view, "td")
      assert above.code in cells
      refute below.code in cells
    end

    # Typed as text, so Arabic digits reach the server to be read, but a
    # phone brings up its number keyboard where the value is never negative.
    test "asks a phone for its number keyboard where it cannot be negative", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/filter_fields?show_custom_filter=true")
      [uuid] = filter_uuids(view)

      filter_change(view, "field_name-#{uuid}", "salary")
      filter_change(view, "operator-#{uuid}", "equals")

      assert attribute(view, "input[name='value-#{uuid}']", "inputmode") == ["numeric"]

      filter_change(view, "field_name-#{uuid}", "code")
      filter_change(view, "operator-#{uuid}", "equals")

      assert attribute(view, "input[name='value-#{uuid}']", "inputmode") == []
    end
  end

  # `AshQuick.AshTypes.Text` is a NewType built on a string, and was never
  # offered.
  describe "a field typed with a NewType" do
    test "is offered and read as the type it is built on", %{conn: conn, admin: admin} do
      word = unique("needle")
      kept = product(name: unique("NT "), description: "with #{word} inside", actor: admin)
      dropped = product(name: unique("NT "), description: "without it", actor: admin)

      {:ok, view, _html} = live(conn, "/products?show_custom_filter=true")
      [uuid] = filter_uuids(view)

      assert "description" in attribute(view, "select[name='field_name-#{uuid}'] option", "value")

      filter_change(view, "field_name-#{uuid}", "description")
      filter_change(view, "operator-#{uuid}", "contains")
      filter_change(view, "value-#{uuid}", word)
      view |> element("#custom-filter-form") |> render_submit()

      assert applied(view) == [{"description", "contains", word}]
      cells = texts(view, "td")
      assert kept.name in cells
      refute dropped.name in cells
    end
  end

  describe "a read too slow to answer" do
    # Slow on purpose, whatever the machine: within this test's transaction
    # the filter's `@?` is one that sleeps on each row it is asked of, so
    # Postgres cancels the filtered read at its `statement_timeout`. The
    # unfiltered read, a page and a count, asks no row by `@?`.
    test "says so, and opens the form holding the filter", %{conn: conn} do
      Ecto.Adapters.SQL.query!(Example.Repo, """
      insert into audit_logs
        (resource_name, resource_id, action_type, action_name, attributes, arguments, context, changes)
      select 'Elixir.Example.Catalog.Product', gen_random_uuid(), 'update', 'update', '{}', '{}', '{}',
        jsonb_build_object('name', jsonb_build_object('from', 'a' || g, 'to', 'b' || g))
      from generate_series(1, 5) g
      """)

      for statement <- [
            "create schema slow_filter",
            """
            create function slow_filter.path_exists(jsonb, jsonpath) returns boolean
              language sql volatile
              as 'select pg_sleep(1) is not null and pg_catalog.jsonb_path_exists($1, $2)'
            """,
            """
            create operator slow_filter.@? (
              leftarg = jsonb, rightarg = jsonpath, function = slow_filter.path_exists
            )
            """,
            "set local search_path = slow_filter, pg_catalog, public",
            "set local statement_timeout = '500ms'"
          ],
          do: Ecto.Adapters.SQL.query!(Example.Repo, statement)

      word = unique("needle")

      filter =
        encode_filter([
          %{"field_name" => "changes", "operator" => "contains", "value" => word, "path" => []}
        ])

      {html, log} =
        with_log(fn ->
          {:ok, _view, html} = live(conn, "/audit_logs?custom_filter=#{filter}")
          html
        end)

      assert html =~ "took too long"
      refute html =~ @refused
      assert log =~ "the read took too long"

      document = LazyHTML.from_fragment(html)
      assert document |> LazyHTML.query("#ash-quick-filter-modal") |> Enum.count() == 1
      assert document |> LazyHTML.query("[data-filter-chip]") |> Enum.count() == 0

      assert document
             |> LazyHTML.query("#custom-filter-form input[name^='value-']")
             |> LazyHTML.attribute("value") == [word]
    end
  end

  defp row(field, operator, value),
    do: %{"field_name" => field, "operator" => operator, "value" => value}

  defp encode_filter(rows) do
    %{"operator" => "and", "children" => rows}
    |> JSON.encode!()
    |> :base64.encode()
    |> URI.encode_www_form()
  end

  defp filter_field(attrs), do: Ash.create!(FilterFields, Map.new(attrs), authorize?: false)

  defp filter_uuids(view) do
    view
    |> attribute("select[name^='field_name-']", "name")
    |> Enum.map(&String.replace_prefix(&1, "field_name-", ""))
  end

  # The rows the URL the form just applied carries, as written there.
  defp applied(view) do
    render(view)
    %URI{query: query} = view |> assert_patch() |> URI.parse()
    %{"custom_filter" => encoded} = URI.decode_query(query)

    for leaf <- encoded |> CustomFilter.from_string() |> CustomFilter.applied_leaves(),
        do: {leaf.field_name, leaf.operator, leaf.value}
  end

  # The filter the URL the form just applied carries, decoded but not read.
  defp url_filter(view) do
    render(view)
    %URI{query: query} = view |> assert_patch() |> URI.parse()
    %{"custom_filter" => encoded} = URI.decode_query(query)
    encoded |> :base64.decode() |> JSON.decode!()
  end

  defp arabic_digits(number) do
    number
    |> Integer.to_string()
    |> String.to_charlist()
    |> Enum.map(&(&1 - ?0 + 0x0660))
    |> List.to_string()
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
