defmodule ExampleWeb.LabelTranslatorScenarioTest do
  @moduledoc """
  The labels AshQuick draws, in the reader's language.

  A label is English wherever it comes from — a humanized field or action
  name, a `label:` option, a nav entry or group, a `one_of` value — and most
  are fixed when the QuickView compiles. `config :ash_quick, label_translator:`
  names `ExampleWeb.Gettext.translate_label/1`, which looks each one up in
  `priv/gettext/ar/LC_MESSAGES/labels.po` as the page renders, against the
  locale `ExampleWeb.UserAuth` put on the process.

  The English admin is the control throughout: the same page drawn for them
  still says what the code says, so an Arabic assertion is about the locale
  rather than about a string that always renders.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.S3Stub

  @export_timeout to_timeout(second: 5)

  setup %{admin: admin} do
    {:ok, arabic: Ash.update!(user(:admin), %{locale: :ar}, actor: admin)}
  end

  test "the list labels its columns, values, controls and nav", ctx do
    %{conn: conn, admin: admin, arabic: arabic} = ctx
    product = product(name: unique("Tent"), tags: [:sale], actor: admin)

    {:ok, view, _html} = live(log_in(conn, arabic), ~p"/products?search=#{product.sku}")

    # A humanized field, a `label:` option and a `one_of` value.
    assert has_element?(view, "th", "الاسم")
    assert has_element?(view, "th", "العلامة التجارية")
    assert has_element?(view, "td", "تخفيض")
    # The `new_action_label`, the saved filter, and the row action.
    assert has_element?(view, "button", "إضافة منتج")
    assert has_element?(view, "label", "عليه تخفيض")
    assert has_element?(view, "#default-sidebar a", "المنتجات")
    assert has_element?(view, "#default-sidebar", "الكتالوج")

    refute has_element?(view, "th", "Name")
    refute has_element?(view, "button", "Add Product")

    # An action, in the row's menu and in the menu over a selection.
    view
    |> element(~s([id="#{product.id}-row-actions-dropdown"] [role="button"]))
    |> render_click()

    assert has_element?(view, ~s([id="#{product.id}-action-reprice"]), "تغيير السعر")

    render_change(view, "table-form-change", %{product.id => "on"})
    assert has_element?(view, "#bulk-actions-menu a", "تغيير السعر")
    refute has_element?(view, "#bulk-actions-menu a", "Reprice")

    {:ok, english, _html} = live(log_in(conn, admin), ~p"/products?search=#{product.sku}")

    assert has_element?(english, "th", "Name")
    assert has_element?(english, "th", "Brand")
    assert has_element?(english, "td", "Sale")
    assert has_element?(english, "button", "Add Product")
    assert has_element?(english, "#default-sidebar a", "Products")
    refute has_element?(english, "th", "الاسم")
  end

  test "the apps grid labels its tiles", %{conn: conn, admin: admin, arabic: arabic} do
    conn
    |> log_in(arabic)
    |> visit(~p"/")
    |> assert_has("main a", text: "الكتالوج")

    conn
    |> log_in(admin)
    |> visit(~p"/")
    |> assert_has("main a", text: "Catalog")
    |> refute_has("main a", text: "الكتالوج")
  end

  test "the details page labels its rows and actions", ctx do
    %{conn: conn, admin: admin, arabic: arabic} = ctx
    product = product(description: "Sleeps four", actor: admin)

    {:ok, view, _html} = live(log_in(conn, arabic), ~p"/products/#{product.id}")

    assert has_element?(view, "[data-field=description]", "الوصف")
    assert has_element?(view, "button", "تعديل")
    refute has_element?(view, "[data-field=description]", "Description")

    {:ok, english, _html} = live(log_in(conn, admin), ~p"/products/#{product.id}")

    assert has_element?(english, "[data-field=description]", "Description")
    assert has_element?(english, "button", "Update")
  end

  test "the form labels its inputs and its title", %{conn: conn, admin: admin, arabic: arabic} do
    {:ok, view, _html} = live(log_in(conn, arabic), ~p"/products/create")

    assert has_element?(view, "label", "الاسم")
    assert has_element?(view, "label", "الوسوم")
    refute has_element?(view, "label", "Name")

    {:ok, english, _html} = live(log_in(conn, admin), ~p"/products/create")

    assert has_element?(english, "label", "Name")
  end

  # The title is sent as an update, so it is read after moving between pages
  # the way a click does.
  test "the page titles name the resource and the action", ctx do
    %{conn: conn, admin: admin, arabic: arabic} = ctx
    product = product(name: unique("Tent"), actor: admin)

    {:ok, view, _html} = live(log_in(conn, arabic), ~p"/products")

    render_patch(view, ~p"/products/#{product.id}")
    assert page_title(view) =~ "منتج - #{product.name}"

    render_patch(view, ~p"/products/create")
    assert page_title(view) =~ "[منتج] إنشاء"

    render_patch(view, ~p"/products")
    assert page_title(view) =~ "المنتجات"

    {:ok, english, _html} = live(log_in(conn, admin), ~p"/products")

    render_patch(english, ~p"/products/create")
    assert page_title(english) =~ "[Product] Create"

    render_patch(english, ~p"/products")
    assert page_title(english) =~ "Products"
  end

  # The export is written by a task, which does not inherit the reader's
  # locale from the LiveView that started it.
  test "an export's header is in the reader's language", ctx do
    %{conn: conn, admin: admin, arabic: arabic} = ctx
    product = product(actor: admin)

    {:ok, view, _html} = live(log_in(conn, arabic), ~p"/products?search=#{product.sku}")
    view |> element("a", "CSV") |> render_click()
    render_async(view, @export_timeout)

    [header | _] = arabic |> exported_csv() |> String.split("\r\n")
    assert header =~ "الاسم"
    refute header =~ "Name"

    {:ok, english, _html} = live(log_in(conn, admin), ~p"/products?search=#{product.sku}")
    english |> element("a", "CSV") |> render_click()
    render_async(english, @export_timeout)

    [header | _] = admin |> exported_csv() |> String.split("\r\n")
    assert header =~ "Name"
  end

  # Exports are keyed by the actor, and every test makes its own users, so
  # this finds exactly the file this test's click produced.
  defp exported_csv(actor) do
    prefix = "exports/#{actor.id}/"

    assert body =
             Enum.find_value(1..40, fn _attempt ->
               case Enum.find(S3Stub.keys(), &String.contains?(&1, prefix)) do
                 nil ->
                   Process.sleep(25)
                   nil

                 key ->
                   S3Stub.body(key)
               end
             end),
           "nothing was uploaded under #{prefix}"

    body
  end
end
