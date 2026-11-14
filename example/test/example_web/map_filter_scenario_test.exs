defmodule ExampleWeb.MapFilterScenarioTest do
  @moduledoc """
  The list's Advanced filters on a map column whose keys are known only at
  runtime: the audit trail's `changes`, on Postgres. A row names a key path
  inside the map, or none to look at every value, and compares what it finds
  there, so one row holding a value of another type never breaks the list.

  Every audited write in the suite lands in the same table, so each test
  looks under a key of its own, and tells its rows apart by `resource_id`.
  """
  use ExampleWeb.FeatureCase, async: true

  alias AshQuick.LiveView.CustomFilter
  alias Example.Accounts.AuditLog

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin), key: unique("k")}
  end

  describe "the form" do
    test "offers a map with a key to type, and what it can ask of it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audit_logs?show_custom_filter=true")
      uuid = filter_uuid(view)

      assert "changes" in attribute(view, "select[name='field_name-#{uuid}'] option", "value")
      refute has_element?(view, "input[name='path-#{uuid}']")

      filter_change(view, "field_name-#{uuid}", "changes")

      assert attribute(view, "input[name='path-#{uuid}']", "placeholder") == ["Any key"]

      assert texts(view, "select[name='operator-#{uuid}'] option") == [
               "Contains",
               "Not Contains",
               "=",
               "!=",
               "Starts With",
               "Ends With",
               ">",
               ">=",
               "<",
               "<=",
               "Key Exists",
               "Key Missing"
             ]

      # Back to a field that is no map, the key goes with it.
      filter_change(view, "field_name-#{uuid}", "ip")
      refute has_element?(view, "input[name='path-#{uuid}']")
    end

    test "refuses Key Exists without a key, under its row", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audit_logs?show_custom_filter=true")
      uuid = filter_uuid(view)

      filter_change(view, "field_name-#{uuid}", "changes")
      filter_change(view, "operator-#{uuid}", "has_key")
      view |> element("#custom-filter-form") |> render_submit()

      assert texts(view, "#value-error-#{uuid}") == ["type the key to look for"]
      assert chips(view) == []
    end
  end

  describe "a key path" do
    # A row holding text where the others hold numbers is the case that breaks
    # a cast: Postgres raises on it, and the whole list fails. Here it just
    # does not match.
    #
    # An audit row holds a decimal as text, `"229.00"`, and that compares as
    # the number it reads as: `"90.00"` is less than 200, though as text it
    # sorts after `"200"`.
    test "compares numbers as numbers, past a row holding text", %{conn: conn, key: key} do
      high = audit(%{key => %{"from" => 5, "to" => 220}})
      low = audit(%{key => %{"from" => 220, "to" => 5}})
      text = audit(%{key => %{"from" => 5, "to" => "abc"}})
      decimal = audit(%{key => %{"to" => "229.00"}})
      small = audit(%{key => %{"to" => "90.00"}})

      view = apply_filter(conn, "#{key}.to", "gt", "200")

      ids = texts(view, "td")
      assert high.resource_id in ids
      assert decimal.resource_id in ids
      refute low.resource_id in ids
      refute text.resource_id in ids
      refute small.resource_id in ids
      refute render(view) =~ "couldn&#39;t be applied"

      assert chips(view) == ["Changes › #{key} › to > 200"]
      assert applied(view) == [{"changes", ["#{key}", "to"], "gt", "200"}]
    end

    # A person cannot tell from how a value reads whether the map holds the
    # number or the text.
    test "reads Equals loosely, as the number or the text", %{conn: conn, key: key} do
      number = audit(%{key => 10})
      text = audit(%{key => "10"})
      decimal = audit(%{key => "10.00"})
      other = audit(%{key => 11})

      ids = conn |> apply_filter(key, "equals", "10") |> texts("td")

      assert number.resource_id in ids
      assert text.resource_id in ids
      assert decimal.resource_id in ids
      refute other.resource_id in ids
    end

    # With no key, every value is compared, and one that reads as no number
    # is passed over rather than ending the search.
    test "compares every value with any key, past ones that are no number", %{
      conn: conn,
      key: key
    } do
      kept =
        audit(%{key => %{"name" => "abc", "nested" => [%{"n" => "x"}, %{"n" => "123456789.5"}]}})

      dropped = audit(%{key => %{"name" => "abc", "n" => 5}})

      ids = conn |> apply_filter("", "gte", "123456789") |> texts("td")

      assert kept.resource_id in ids
      refute dropped.resource_id in ids
    end

    # Lax mode reads through a list: a row matches when any item does.
    test "reads through a list of maps", %{conn: conn, key: key} do
      kept = audit(%{key => [%{"sku" => "A-1"}, %{"sku" => "B.2"}]})
      dropped = audit(%{key => [%{"sku" => "A-1"}]})

      ids = conn |> apply_filter("#{key}.sku", "equals", "B.2") |> texts("td")

      assert kept.resource_id in ids
      refute dropped.resource_id in ids
    end

    # A key holding `null` is there; one never written is not.
    test "tells a key holding null from a missing one", %{conn: conn, key: key} do
      null = audit(%{key => nil, "#{key}-x" => 1})
      missing = audit(%{"#{key}-x" => 1})

      ids = conn |> apply_filter(key, "has_key", nil) |> texts("td")
      assert null.resource_id in ids
      refute missing.resource_id in ids

      view = apply_filter(conn, key, "missing_key", nil)
      assert missing.resource_id in texts(view, "td")
      refute null.resource_id in texts(view, "td")
      assert chips(view) == ["Changes › #{key} is missing"]
    end

    # Not Equals keeps a row that holds the key with another value, as a
    # column's Not Equals keeps one that has a value.
    test "keeps under Not Equals only rows holding the key", %{conn: conn, key: key} do
      other = audit(%{key => "b"})
      same = audit(%{key => "a"})
      missing = audit(%{"#{key}-x" => "b"})

      ids = conn |> apply_filter(key, "not_equals", "a") |> texts("td")

      assert other.resource_id in ids
      refute same.resource_id in ids
      refute missing.resource_id in ids
    end
  end

  describe "a long number" do
    # Past 100 digits a value is compared as text, rather than as a number
    # anything parsing it might refuse.
    test "is compared, from the form and from a link", %{conn: conn, key: key} do
      long = String.duplicate("9", 40)
      kept = audit(%{key => String.duplicate("9", 41)})
      dropped = audit(%{key => 5})

      ids = conn |> apply_filter(key, "gt", long) |> texts("td")
      assert kept.resource_id in ids
      refute dropped.resource_id in ids

      longer = String.duplicate("9", 101)
      row = %{"field_name" => "changes", "path" => [key], "operator" => "gt", "value" => longer}
      {:ok, view, _html} = live(conn, "/audit_logs?custom_filter=#{encode_filter([row])}")
      refute render(view) =~ "couldn&#39;t be applied"
    end
  end

  describe "any key" do
    # What a reader of an audit trail most often asks: anything mentioning it.
    test "Contains looks at every value at any depth, ignoring case", %{conn: conn, key: key} do
      kept = audit(%{key => %{"to" => %{"name" => "#{key} ACME (East) Ltd"}}})
      dropped = audit(%{key => %{"to" => "#{key} Other"}})

      view = apply_filter(conn, "", "contains", "#{key} acme (east)")

      ids = texts(view, "td")
      assert kept.resource_id in ids
      refute dropped.resource_id in ids
      assert chips(view) == ["Changes › any key contains #{key} acme (east)"]
    end

    # The value is matched as written: a `.` or `*` is no wildcard, and a
    # quote or backslash does not end the string the path holds it in.
    test "reads every character of the value as itself", %{conn: conn, key: key} do
      kept = audit(%{key => ~s(#{key} a.b*"c\\d)})
      dropped = audit(%{key => "#{key} aXbbbb"})

      ids = conn |> apply_filter("", "contains", ~s(#{key} a.b*"c\\d)) |> texts("td")

      assert kept.resource_id in ids
      refute dropped.resource_id in ids
    end
  end

  describe "a field policy" do
    alias Example.Test.HiddenChanges

    # Ash reads a hidden field as `nil` where a filter names it, but not
    # inside the SQL a map row is asked as. Were the row asked of the column
    # alone, Contains would read a hidden value back a character at a time.
    test "keeps no row whose map the reader may not see", %{key: key} do
      shown = audit(%{key => "secret"}, ip: "shown")
      hidden = audit(%{key => "secret"}, ip: "hidden")

      for {operator, value} <- [
            {"equals", "secret"},
            {"contains", "sec"},
            {"starts_with", "s"},
            {"not_equals", "other"},
            {"not_contains", "other"},
            {"has_key", nil}
          ] do
        ids = read(HiddenChanges, [key], operator, value, %{role: :viewer})
        assert shown.resource_id in ids, operator
        refute hidden.resource_id in ids, operator

        ids = read(HiddenChanges, [key], operator, value, %{role: :admin})
        assert shown.resource_id in ids, operator
        assert hidden.resource_id in ids, operator
      end
    end

    # Key Missing keeps a map the reader may not see as one holding nothing,
    # as Is Empty does a hidden field: it gives no value back. The list
    # refuses it on a map hidden on some rows, as it does Is Empty.
    test "reads a hidden map as holding no key", %{key: key} do
      shown = audit(%{key => "secret"}, ip: "shown")
      hidden = audit(%{key => "secret"}, ip: "hidden")

      ids = read(HiddenChanges, [key], "missing_key", nil, %{role: :viewer})
      refute shown.resource_id in ids
      assert hidden.resource_id in ids

      refute hidden.resource_id in read(HiddenChanges, [key], "missing_key", nil, %{role: :admin})
    end
  end

  describe "a link" do
    # A key can hold anything, quotes included, and is read as one key: it
    # cannot end the key early and add to the path.
    test "reads a key with quotes in it as one key", %{conn: conn, key: key} do
      odd = ~s(#{key}" ? (@ == "x"\) || $ ? (@ == "1)
      kept = audit(%{odd => "x"})
      dropped = audit(%{key => "x"})

      filter =
        encode_filter([
          %{"field_name" => "changes", "path" => [odd], "operator" => "equals", "value" => "x"}
        ])

      {:ok, view, _html} = live(conn, "/audit_logs?custom_filter=#{filter}")

      ids = texts(view, "td")
      assert kept.resource_id in ids
      refute dropped.resource_id in ids
    end

    # The form writes a key path on a map row and none on any other, and an
    # operator a map row offers; a link holding anything else is refused.
    test "is refused when its row does not fit its field", %{conn: conn, key: key} do
      audit(%{key => "x"})

      rows = [
        %{"field_name" => "ip", "path" => [key], "operator" => "equals", "value" => "x"},
        %{"field_name" => "changes", "operator" => "equals", "value" => "x"},
        %{"field_name" => "changes", "path" => [key], "operator" => "in", "value" => ["x"]},
        %{"field_name" => "changes", "path" => [], "operator" => "has_key"},
        # A key the form would split in two, or trim, were the row edited.
        %{"field_name" => "changes", "path" => ["a.b"], "operator" => "equals", "value" => "x"},
        %{"field_name" => "changes", "path" => [" a"], "operator" => "equals", "value" => "x"},
        %{"field_name" => "changes", "path" => [""], "operator" => "equals", "value" => "x"}
      ]

      for row <- rows do
        {:ok, view, _html} = live(conn, "/audit_logs?custom_filter=#{encode_filter([row])}")

        assert render(view) =~ "couldn&#39;t be applied", inspect(row)
        assert chips(view) == [], inspect(row)
      end
    end

    # A path holding anything but keys is no filter the form could write, and
    # reads as none, as any malformed link does.
    test "reads a path of anything but keys as no filter", %{conn: conn} do
      row = %{"field_name" => "changes", "path" => [1], "operator" => "equals", "value" => "x"}
      {:ok, view, _html} = live(conn, "/audit_logs?custom_filter=#{encode_filter([row])}")

      refute render(view) =~ "couldn&#39;t be applied"
      assert chips(view) == []
    end
  end

  defp audit(changes, attrs \\ []) do
    Ash.create!(
      AuditLog,
      %{
        resource_name: :map_filter,
        resource_id: Ash.UUID.generate(),
        action_type: :update,
        action_name: :update,
        attributes: %{},
        arguments: %{},
        context: %{},
        changes: changes,
        ip: attrs[:ip]
      },
      authorize?: false
    )
  end

  # The `resource_id`s of `resource`'s rows a map row on `changes` keeps, read
  # as `actor`.
  defp read(resource, path, operator, value, actor) do
    filter =
      CustomFilter.build_ash_filter(%CustomFilter{
        uuid: "root",
        operator: "and",
        children: [
          %CustomFilter{
            uuid: "row",
            field_name: "changes",
            path: path,
            operator: operator,
            value: value
          }
        ]
      })

    resource
    |> Ash.Query.filter_input(filter)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.resource_id)
  end

  # Opens the filter on the audit trail, sets its one row on `changes` at
  # `path`, typed with dots, and applies it.
  defp apply_filter(conn, path, operator, value) do
    {:ok, view, _html} = live(conn, "/audit_logs?show_custom_filter=true")
    uuid = filter_uuid(view)

    filter_change(view, "field_name-#{uuid}", "changes")
    filter_change(view, "path-#{uuid}", path)
    filter_change(view, "operator-#{uuid}", operator)
    if value, do: filter_change(view, "value-#{uuid}", value)
    view |> element("#custom-filter-form") |> render_submit()

    view
  end

  defp encode_filter(rows) do
    %{"operator" => "and", "children" => rows}
    |> JSON.encode!()
    |> :base64.encode()
    |> URI.encode_www_form()
  end

  defp filter_uuid(view) do
    [name] = attribute(view, "select[name^='field_name-']", "name")
    String.replace_prefix(name, "field_name-", "")
  end

  # The rows the URL the form just applied carries, as written there. See
  # `ExampleWeb.CustomFilterScenarioTest`'s.
  defp applied(view) do
    render(view)
    %URI{query: query} = view |> assert_patch() |> URI.parse()
    %{"custom_filter" => encoded} = URI.decode_query(query)

    for leaf <- encoded |> CustomFilter.from_string() |> CustomFilter.applied_leaves(),
        do: {leaf.field_name, leaf.path, leaf.operator, leaf.value}
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
