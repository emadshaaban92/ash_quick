defmodule ExampleWeb.AccessibilityScenarioTest do
  @moduledoc """
  What a keyboard and a screen reader get from AshQuick's own markup.

  Every input, select and button in the filter form and on a details page has
  a name, and an input refused on save points at the error drawn under it.
  Every dropdown is a menu button: a `<button>` saying it opens a menu and
  whether it is open, over a `role="menu"` of `menuitem`s. Every modal is a
  `<dialog>` its hook opens with `showModal()`.

  The keys themselves (↓, ↑, Home, End, Escape) and the dialog's focus are the
  hooks' work, which LiveViewTest does not run; what is checked here is the
  markup they work on.

  A control is named here as a browser names it: by `aria-label`,
  `aria-labelledby`, a `<label>` that holds it or names its id, or, for a
  button or a link, its text. LiveSelect's search input takes no attributes,
  so its name is set by the picker's hook from the `data-label` it wraps it
  in, and that is what is checked for it.
  """
  use ExampleWeb.FeatureCase, async: true

  import ExampleWeb.FilterPicker, only: [picker_id: 2]

  describe "the filter form" do
    setup %{conn: conn, admin: admin} do
      {:ok, conn: log_in(conn, admin)}
    end

    test "names every control, in a nested group too", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/filter_fields?show_custom_filter=true")
      ["operator-" <> group | _] = attribute(view, "select[name^='operator-']", "name")

      view
      |> element("#custom-filter-form button[phx-value-uuid='#{group}'][phx-value-nested='true']")
      |> render_click()

      assert unnamed(view, "#custom-filter-form") == []

      assert names(view, "#custom-filter-form select[name^='operator-']") ==
               ["Match", "Operator", "Match", "Operator"]

      assert names(view, "#custom-filter-form select[name^='field_name-']") == ["Field", "Field"]

      assert names(view, "#custom-filter-form button.btn-error") ==
               ["Remove filter", "Remove group", "Remove filter"]
    end

    # Each value input a field or an operator draws: text, a timestamp, a
    # day, a boolean, a fixed set, and the typed and picked lists.
    test "names the value input every field and operator draws", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/filter_fields?show_custom_filter=true")
      [uuid] = attribute(view, "select[name^='field_name-']", "name")
      uuid = String.replace_prefix(uuid, "field_name-", "")

      for {field, operator} <- [
            {"code", "equals"},
            {"code", "in"},
            {"stamped_at", "gt"},
            {"stamped_at", "on"},
            {"salary", "gt"},
            {"active", "equals"},
            {"stage", "equals"}
          ] do
        filter_change(view, "field_name-#{uuid}", field)
        filter_change(view, "operator-#{uuid}", operator)

        assert names(view, "#custom-filter-form [name='value-#{uuid}']") == ["Value"],
               "#{field} #{operator}"

        assert unnamed(view, "#custom-filter-form") == [], "#{field} #{operator}"
      end

      filter_change(view, "field_name-#{uuid}", "stage")
      filter_change(view, "operator-#{uuid}", "in")

      assert attribute(view, "##{picker_id(view, uuid)}-wrap", "data-label") == ["Value"]
    end
  end

  describe "a map row" do
    setup %{conn: conn, admin: admin} do
      {:ok, conn: log_in(conn, admin)}
    end

    test "names its key input", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audit_logs?show_custom_filter=true")
      [uuid] = attribute(view, "select[name^='field_name-']", "name")
      uuid = String.replace_prefix(uuid, "field_name-", "")

      filter_change(view, "field_name-#{uuid}", "changes")

      assert names(view, "#custom-filter-form [name='path-#{uuid}']") == ["Key"]
      assert unnamed(view, "#custom-filter-form") == []
    end
  end

  describe "a details page" do
    test "names its back link and its More actions button", %{conn: conn, admin: admin} do
      product = product(name: "Named tent", actor: admin)
      {:ok, view, _html} = conn |> log_in(admin) |> live("/products?id=#{product.id}")

      assert names(view, "section a:has(.hero-arrow-left)") == ["Back to list"]
      assert names(view, "#details-more-actions-dropdown [data-menu-trigger]") == ["More actions"]
      assert_menu(view, "details-more-actions-dropdown")
    end
  end

  describe "a refused save" do
    test "ties each input's errors to it", %{conn: conn, admin: admin} do
      conn
      |> log_in(admin)
      |> visit(~p"/test/digits_only/create")
      |> fill_in("Code", with: "12ab")
      |> click_button("Save")
      |> assert_has(".text-error", text: "must be digits")
      |> unwrap(fn view ->
        html = view |> render() |> LazyHTML.from_fragment()
        invalid = LazyHTML.query(html, "[aria-invalid='true']")

        assert Enum.count(invalid) == 2

        for input <- invalid do
          [errors_id] = LazyHTML.attribute(input, "aria-describedby")
          errors = LazyHTML.query(html, "##{errors_id} p.text-error")

          assert Enum.count(errors) == 1, errors_id
        end

        send(self(), {:errors, texts(view, "[id$='-errors'] p.text-error")})
        render(view)
      end)

      assert_received {:errors, errors}
      assert Enum.sort(errors) == ["is required", "must be digits"]
    end
  end

  describe "a list's menus" do
    setup %{conn: conn, admin: admin} do
      product = product(name: "Menu tent", actor: admin)
      {:ok, view, _html} = conn |> log_in(admin) |> live("/products")
      %{view: view, product: product}
    end

    test "are menu buttons, a row's once its entries arrive", %{view: view, product: product} do
      row = "#{product.id}-row-actions-dropdown"
      view |> element("##{row} [data-menu-trigger]") |> render_click()

      assert_menu(view, row)
      assert names(view, "##{row} [data-menu-trigger]") == ["Row actions"]
      assert names(view, "##{row} [role='menuitem']") |> Enum.member?("Update")
      assert_menu(view, "export-menu")
    end

    test "a cell's, once opened", %{view: view, product: product} do
      cell = "#{product.id}-cell-filter-name"
      view |> element(~s([id="#{cell}"] [data-menu-trigger])) |> render_click()

      assert_menu(view, cell)
      assert names(view, ~s([id="#{cell}"] [data-menu-trigger])) == ["Filter by this cell"]
    end

    # A page holds a menu per row and per filterable cell, so they share one
    # hook on the list's section rather than mounting one each.
    test "share one hook", %{view: view} do
      html = view |> render() |> LazyHTML.from_fragment()

      assert html |> LazyHTML.query("[data-menu]") |> Enum.count() > 1

      assert html
             |> LazyHTML.query("[data-menu][phx-hook], [data-menu] [phx-hook]")
             |> Enum.empty?()

      assert html |> LazyHTML.query("section:has([data-menu])") |> LazyHTML.attribute("phx-hook") ==
               ["AshQuick.LiveView.Components.Menu.Menus"]
    end

    # Tabbing to a trigger used to open its menu, and ask the server for its
    # entries, on focus: only a click opens one now.
    test "open on a click, not on focus", %{view: view} do
      refute view |> render() |> String.contains?("phx-focus")
    end
  end

  describe "a modal" do
    test "is a dialog its hook opens as a modal", %{conn: conn, admin: admin} do
      {:ok, view, _html} = conn |> log_in(admin) |> live("/products?show_custom_filter=true")
      html = view |> render() |> LazyHTML.from_fragment()
      dialog = LazyHTML.query(html, "dialog#ash-quick-filter-modal")

      assert LazyHTML.attribute(dialog, "phx-hook") ==
               ["AshQuick.LiveView.Components.ActionModal.ActionModal"]

      [mounted] = LazyHTML.attribute(dialog, "phx-mounted")
      assert mounted =~ "ignore_attrs"
      assert mounted =~ "open"
    end
  end

  describe "a flash raised while the modal is open" do
    # The host's flash sits under the modal's backdrop, inert, so the modal
    # draws it itself, as an alert a screen reader reads out.
    test "is shown in the modal as an alert", %{conn: conn, admin: admin} do
      conn
      |> log_in(admin)
      |> visit(~p"/test/digits_only/create?action=quick")
      |> fill_in("Code", with: "123")
      |> fill_in("Name", with: "Digits")
      |> click_button("Save")
      |> assert_has("dialog [role='alert']", text: "Ref: must match ~r/^[A-Z]+$/")
      |> assert_has("dialog [role='alert'] button[aria-label='Dismiss']")
    end

    # A link that opens the filter modal on a filter the list refuses.
    test "is shown in the filter modal too", %{conn: conn, admin: admin} do
      filter =
        encode_filter([%{"field_name" => "pin", "operator" => "starts_with", "value" => "pin-4"}])

      {:ok, view, _html} =
        conn
        |> log_in(admin)
        |> live("/test/secrets?show_custom_filter=true&custom_filter=#{filter}")

      assert has_element?(
               view,
               "dialog#ash-quick-filter-modal [role='alert']",
               "That filter couldn't be applied to this list"
             )
    end

    # Dismissing it re-renders the modal, which must not hand the filter
    # form the URL's filter again over the rows being edited.
    test "is dismissed in the filter modal without dropping the rows added", %{
      conn: conn,
      admin: admin
    } do
      filter =
        encode_filter([%{"field_name" => "pin", "operator" => "starts_with", "value" => "pin-4"}])

      {:ok, view, _html} =
        conn
        |> log_in(admin)
        |> live("/test/secrets?show_custom_filter=true&custom_filter=#{filter}")

      assert filter_rows(view) == 1
      view |> element("#custom-filter-form button[phx-value-nested='false']") |> render_click()
      assert filter_rows(view) == 2

      view
      |> element("dialog#ash-quick-filter-modal [role='alert'] button[aria-label='Dismiss']")
      |> render_click()

      refute has_element?(view, "dialog#ash-quick-filter-modal [role='alert']")
      assert filter_rows(view) == 2
    end
  end

  defp filter_rows(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#custom-filter-form select[name^='field_name-']")
    |> Enum.count()
  end

  defp encode_filter(rows) do
    %{"operator" => "and", "children" => rows}
    |> JSON.encode!()
    |> :base64.encode()
    |> URI.encode_www_form()
  end

  # A menu button: a button over the list it opens, shut, whose entries are
  # reached by the arrow keys rather than Tab.
  defp assert_menu(view, id) do
    html = view |> render() |> LazyHTML.from_fragment()
    trigger = LazyHTML.query(html, ~s([id="#{id}"] > button[data-menu-trigger]))

    assert LazyHTML.attribute(trigger, "aria-haspopup") == ["menu"]
    assert LazyHTML.attribute(trigger, "aria-expanded") == ["false"]
    assert LazyHTML.attribute(trigger, "aria-controls") == ["#{id}-content"]

    menu = LazyHTML.query(html, ~s([id="#{id}-content"]))
    assert LazyHTML.attribute(menu, "role") == ["menu"]
    assert LazyHTML.attribute(menu, "aria-labelledby") == ["#{id}-trigger"]

    items = LazyHTML.query(menu, "[role='menuitem']")
    assert Enum.count(items) > 0

    for item <- items, LazyHTML.attribute(item, "aria-disabled") != ["true"] do
      assert LazyHTML.attribute(item, "tabindex") == ["-1"]
    end

    for li <- LazyHTML.query(menu, "li"), do: assert(LazyHTML.attribute(li, "role") == ["none"])
  end

  # The name a browser gives each control the selector matches.
  defp names(view, selector) do
    html = view |> render() |> LazyHTML.from_fragment()
    html |> LazyHTML.query(selector) |> Enum.map(&name(&1, html))
  end

  # The controls under `scope` a browser would give no name: what a screen
  # reader would announce as only "button" or "edit text".
  defp unnamed(view, scope) do
    html = view |> render() |> LazyHTML.from_fragment()

    html
    |> LazyHTML.query(
      "#{scope} select, #{scope} textarea, #{scope} button, " <>
        "#{scope} input:not([type='hidden'])"
    )
    |> Enum.reject(&live_select_input?(&1, html))
    |> Enum.filter(&(name(&1, html) in [nil, ""]))
    |> Enum.map(&LazyHTML.to_html/1)
  end

  # LiveSelect's search input, which the picker's hook names.
  defp live_select_input?(node, html) do
    case LazyHTML.attribute(node, "id") do
      [id] -> html |> LazyHTML.query("[data-label] ##{id}") |> Enum.any?()
      _ -> false
    end
  end

  defp name(node, html) do
    cond do
      (label = first(node, "aria-label")) != nil ->
        label

      (ids = first(node, "aria-labelledby")) != nil ->
        ids
        |> String.split()
        |> Enum.map_join(" ", &(html |> LazyHTML.query("##{&1}") |> LazyHTML.text()))
        |> String.trim()

      (id = first(node, "id")) != nil and
          Enum.any?(LazyHTML.query(html, "label[for='#{id}']")) ->
        html |> LazyHTML.query("label[for='#{id}']") |> LazyHTML.text() |> String.trim()

      LazyHTML.tag(node) == ["button"] or LazyHTML.tag(node) == ["a"] ->
        node |> LazyHTML.text() |> String.trim()

      true ->
        nil
    end
  end

  defp first(node, attribute), do: node |> LazyHTML.attribute(attribute) |> List.first()

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
