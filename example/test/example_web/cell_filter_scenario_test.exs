defmodule ExampleWeb.CellFilterScenarioTest do
  @moduledoc """
  A list cell's own filter menu: a cell of a column the filter offers opens
  a menu that filters the list by what the cell holds, or filters it out,
  beside whatever the list is filtered by already.

  On `/products`, whose `filterable:` adds the brand's and the category's
  names, on `/audit_logs`, whose `changes` is a map, and on
  `/test/filter_fields_cells`, whose fields a field policy hides. The tables are
  shared with other async cases, so each test starts from a filter on names
  or ids it made unique.
  """
  use ExampleWeb.FeatureCase, async: true

  alias AshQuick.LiveView.CustomFilter

  @refused "That filter couldn&#39;t be applied to this list"

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin), prefix: unique("Cell ")}
  end

  describe "a cell's menu" do
    test "is offered on a column the filter offers, and no other", %{
      conn: conn,
      admin: admin,
      prefix: prefix
    } do
      product(actor: admin, name: "#{prefix}a")
      view = products(conn, prefix)

      assert has_element?(view, "[data-cell-filter='name']")
      assert has_element?(view, "[data-cell-filter='brand.name']")
      assert has_element?(view, "[data-cell-filter='price']")
      # A list of images, and a column naming a related record, are no field
      # the filter offers.
      refute has_element?(view, "[data-cell-filter='images']")
      refute has_element?(view, "[data-cell-filter='store']")
    end

    # Each cell drawing its menu's words would make every cell read them.
    test "draws its entries only once it is opened", %{conn: conn, admin: admin, prefix: prefix} do
      product = product(actor: admin, name: "#{prefix}a")
      view = products(conn, prefix)

      refute has_element?(view, choice(product, "name", "equals"))
      assert "#{prefix}a" in texts(view, "td")

      open_menu(view, product, "name")

      assert texts(view, menu(product, "name") <> " li") == [
               "Filter by this value",
               "Filter out this value"
             ]
    end
  end

  describe "a value" do
    test "filters the list by it, beside the filter applied", %{
      conn: conn,
      admin: admin,
      prefix: prefix
    } do
      kept = product(actor: admin, name: "#{prefix}a")
      dropped = product(actor: admin, name: "#{prefix}b")
      view = products(conn, prefix)

      pick(view, kept, "name", "equals")

      cells = texts(view, "td")
      assert kept.name in cells
      refute dropped.name in cells
      assert chips(view) == ["Name starts with #{prefix}", "Name = #{prefix}a"]
      refute render(view) =~ @refused
    end

    test "filters it out", %{conn: conn, admin: admin, prefix: prefix} do
      out = product(actor: admin, name: "#{prefix}a")
      kept = product(actor: admin, name: "#{prefix}b")
      view = products(conn, prefix)

      pick(view, out, "name", "not_equals")

      cells = texts(view, "td")
      assert kept.name in cells
      refute out.name in cells
      assert chips(view) == ["Name starts with #{prefix}", "Name != #{prefix}a"]
    end

    # The column shows the brand's name, so that is what the row names: a
    # host offers it with `filterable:` and configures nothing else.
    test "of a related record filters by the field its column shows", %{
      conn: conn,
      admin: admin,
      prefix: prefix
    } do
      brand = brand(actor: admin, name: "#{prefix}brand")
      kept = product(actor: admin, name: "#{prefix}a", brand: brand)
      dropped = product(actor: admin, name: "#{prefix}b")
      view = products(conn, prefix)

      path = pick(view, kept, "brand.name", "equals")

      cells = texts(view, "td")
      assert kept.name in cells
      refute dropped.name in cells
      assert {"brand.name", "equals", brand.name} in applied(path)
    end

    # An Or root keeps a row matching any of its rows, so the new row goes
    # beside the whole of it, and the list only narrows.
    test "narrows a list filtered by any of several rows", %{
      conn: conn,
      admin: admin,
      prefix: prefix
    } do
      kept = product(actor: admin, name: "#{prefix}a", tags: [:sale])
      dropped = product(actor: admin, name: "#{prefix}b", tags: [:new])

      filter =
        encode_filter(
          [
            %{"field_name" => "name", "operator" => "equals", "value" => kept.name},
            %{"field_name" => "name", "operator" => "equals", "value" => dropped.name}
          ],
          "or"
        )

      {:ok, view, _html} = live(conn, "/products?custom_filter=#{filter}")

      pick(view, kept, "tags", "has_any")

      cells = texts(view, "td")
      assert kept.name in cells
      refute dropped.name in cells
      assert chips(view) == ["Any of 2 conditions", "Tags has any of Sale"]
    end
  end

  describe "an empty cell" do
    test "filters by its being empty", %{conn: conn, admin: admin, prefix: prefix} do
      tagged = product(actor: admin, name: "#{prefix}a", tags: [:sale])
      empty = product(actor: admin, name: "#{prefix}b", tags: [])
      view = products(conn, prefix)

      pick(view, empty, "tags", "is_nil")

      cells = texts(view, "td")
      assert empty.name in cells
      refute tagged.name in cells
      assert chips(view) == ["Name starts with #{prefix}", "Tags is empty"]
    end
  end

  describe "a map" do
    test "filters by a value at a key, a level down too", %{conn: conn} do
      key = unique("k")
      kept = audit(%{key => %{"from" => 5, "to" => 7}})
      dropped = audit(%{key => %{"from" => 5, "to" => 8}})

      filter =
        encode_filter(
          [
            %{
              "field_name" => "changes",
              "path" => [key],
              "operator" => "has_key",
              "value" => ""
            }
          ],
          "and"
        )

      {:ok, view, _html} = live(conn, "/audit_logs?custom_filter=#{filter}")

      open_menu(view, kept, "changes")

      assert texts(view, menu(kept, "changes") <> " li") == [
               "#{key} › from is 5",
               "#{key} › to is 7"
             ]

      view
      |> element(menu(kept, "changes") <> " button", "to is 7")
      |> render_click()

      assert {"changes", "equals", "7"} in applied(assert_patch(view))

      ids = texts(view, "td")
      assert kept.resource_id in ids
      refute dropped.resource_id in ids
      assert chips(view) == ["Changes › #{key} exists", "Changes › #{key} › to = 7"]
    end
  end

  describe "a field policy" do
    # Ash reads a memo the editor may not see as `nil`, so the list refuses
    # Is Empty on it: an editor's empty memo offers no menu at all, as
    # opening one would offer nothing.
    test "leaves Is Empty out on a field it hides on some rows", %{
      conn: conn,
      admin: admin,
      editor: editor
    } do
      code = unique("CF")
      empty = filter_field(code: "#{code}-empty", active: true)
      noted = filter_field(code: "#{code}-noted", memo: "kept", active: true)

      view = filter_fields(log_in(conn, editor), code)
      refute has_element?(view, menu(empty, "memo"))
      open_menu(view, noted, "memo")

      assert texts(view, menu(noted, "memo") <> " li") == [
               "Filter by this value",
               "Filter out this value"
             ]

      view = filter_fields(log_in(conn, admin), code)
      open_menu(view, empty, "memo")
      assert texts(view, menu(empty, "memo") <> " li") == ["Filter by empty", "Filter out empty"]
    end

    # A salary only an admin may see is no column of the editor's list, and
    # no field the editor's filter offers, so no cell offers it either.
    test "leaves out a column it hides on every row", %{conn: conn, admin: admin, editor: editor} do
      code = unique("CF")
      row = filter_field(code: "#{code}-a", salary: 5, active: true)

      assert has_element?(filter_fields(log_in(conn, admin), code), menu(row, "salary"))

      view = filter_fields(log_in(conn, editor), code)
      refute has_element?(view, "[data-cell-filter='salary']")
      assert has_element?(view, menu(row, "code"))
    end
  end

  # Each case opens the cell's menu first, so the pick is refused for what it
  # names, not for there being no menu open.
  describe "a forged pick" do
    test "of an entry the open menu does not hold filters by nothing, and says so", %{
      conn: conn,
      admin: admin,
      prefix: prefix
    } do
      product = product(actor: admin, name: "#{prefix}a")
      other = product(actor: admin, name: "#{prefix}b")
      view = products(conn, prefix)

      forged = [
        {product.id, "name", 7},
        {product.id, "name", -1},
        {product.id, "name", "x"},
        {other.id, "name", 0},
        {product.id, "images", 0}
      ]

      for {id, column, choice} <- forged do
        open_menu(view, product, "name")
        render_hook(view, "cell_filter", %{id: id, column: column, choice: choice})

        assert render(view) =~ @refused
        assert chips(view) == ["Name starts with #{prefix}"]
      end

      # The menu the forged picks were sent beside still applies its own.
      pick(view, product, "name", "equals")
      assert chips(view) == ["Name starts with #{prefix}", "Name = #{prefix}a"]
    end
  end

  # The products whose names start with `prefix`, filtered so by a link.
  defp products(conn, prefix) do
    filter =
      encode_filter([%{"field_name" => "name", "operator" => "starts_with", "value" => prefix}])

    {:ok, view, _html} = live(conn, "/products?custom_filter=#{filter}")
    view
  end

  # The `/test/filter_fields_cells` rows whose codes start with `code`.
  defp filter_fields(conn, code) do
    filter =
      encode_filter([%{"field_name" => "code", "operator" => "starts_with", "value" => code}])

    {:ok, view, _html} = live(conn, "/test/filter_fields_cells?custom_filter=#{filter}")
    view
  end

  defp filter_field(attrs),
    do: Ash.create!(Example.Test.FilterFields, Map.new(attrs), authorize?: false)

  defp menu(record, column), do: ~s(tr[id="#{row_id(record)}"] [data-cell-filter="#{column}"])

  defp choice(record, column, operator),
    do: menu(record, column) <> ~s( button[data-cell-filter-choice="#{operator}"])

  defp open_menu(view, record, column) do
    view |> element(menu(record, column) <> " [role=button]") |> render_click()
  end

  # The page's path once the pick is applied.
  defp pick(view, record, column, operator) do
    open_menu(view, record, column)
    view |> element(choice(record, column, operator)) |> render_click()
    assert_patch(view)
  end

  # An audit row's cells are drawn under the row's own id; the test tells
  # them apart by `resource_id`.
  defp row_id(%{id: id}), do: id

  defp audit(changes) do
    Ash.create!(
      Example.Accounts.AuditLog,
      %{
        resource_name: :cell_filter,
        resource_id: Ash.UUID.generate(),
        action_type: :update,
        action_name: :update,
        attributes: %{},
        arguments: %{},
        context: %{},
        changes: changes
      },
      authorize?: false
    )
  end

  # The rows of the filter `path` carries, each as its field, operator and
  # value.
  defp applied(path) do
    %{"custom_filter" => encoded} =
      path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    encoded
    |> CustomFilter.from_string()
    |> CustomFilter.leaves()
    |> Enum.map(&{&1.field_name, &1.operator, &1.value})
  end

  defp encode_filter(rows, operator \\ "and") do
    %{"operator" => operator, "children" => rows}
    |> JSON.encode!()
    |> :base64.encode()
    |> URI.encode_www_form()
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
