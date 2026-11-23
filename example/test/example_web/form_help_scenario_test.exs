defmodule ExampleWeb.FormHelpScenarioTest do
  @moduledoc """
  The help text under a form input: only what a `help` entry of its resource
  declares, on every form or on one action's, in the reader's language, and
  named by the input's `aria-describedby` beside its errors. A field's Ash
  `description` is never drawn.

  `Example.Catalog.Product` describes `:sku` and `:price` for an API's
  readers. It declares help for `:price` on every form and another for its
  `:reprice` form, for `:sku` on its `:update` form only, and for `:brand`.
  """
  use ExampleWeb.FeatureCase, async: true

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin), product: product(actor: admin)}
  end

  defp html(view), do: view |> render() |> LazyHTML.from_fragment()

  defp input(html, field), do: LazyHTML.query(html, "input[name='form[#{field}]']")

  defp described_by(input) do
    case LazyHTML.attribute(input, "aria-describedby") do
      [ids] -> String.split(ids)
      [] -> []
    end
  end

  defp help(html, id), do: html |> LazyHTML.query("[id='#{id}']") |> LazyHTML.text()

  defp helps(view),
    do:
      view
      |> html()
      |> LazyHTML.query("[data-field-help]")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

  test "a described field with no help entry draws no help", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/products/create")
    helps = helps(view)

    assert described_by(input(html(view), "sku")) == []
    refute Enum.any?(helps, &(&1 =~ "stock code"))
    refute Enum.any?(helps, &(&1 =~ "minor units"))
    assert Enum.sort(helps) == ["Before tax.", "Who makes it, as printed on the box."]
  end

  test "help for every form is drawn on each form that draws the field", ctx do
    %{conn: conn, product: product} = ctx

    for path <- [~p"/products/create", ~p"/products/#{product.id}/update"] do
      {:ok, view, _html} = live(conn, path)
      helps = helps(view)

      assert "Before tax." in helps
      assert "Who makes it, as printed on the box." in helps
    end
  end

  test "help for one action is drawn on that action's form only", ctx do
    %{conn: conn, product: product} = ctx

    {:ok, view, _html} = live(conn, ~p"/products/#{product.id}/update")
    html = html(view)
    sku = input(html, "sku")

    [help_id] = described_by(sku)
    assert help_id == "#{LazyHTML.attribute(sku, "id") |> hd()}-help"
    assert help(html, help_id) =~ "Changing it breaks the labels already printed."

    {:ok, view, _html} = live(conn, ~p"/products/create")
    refute "Changing it breaks the labels already printed." in helps(view)
  end

  test "help for one action wins over help for every form there", ctx do
    %{conn: conn, product: product} = ctx

    {:ok, view, _html} = live(conn, ~p"/products/#{product.id}/reprice")

    assert helps(view) == ["The new price, before tax."]
  end

  # The picker's text box takes the field's id, so it is described by the
  # help under it, and by its errors once a save is refused.
  test "draws a relationship's help under its dropdown, and names it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/products/create")

    assert "Who makes it, as printed on the box." in helps(view)
    box = view |> html() |> LazyHTML.query("#form_brand_id")
    assert LazyHTML.attribute(box, "role") == ["combobox"]
    assert described_by(box) == ["form_brand_id-help"]
    assert help(html(view), "form_brand_id-help") =~ "Who makes it, as printed on the box."
    assert LazyHTML.attribute(box, "aria-invalid") == []

    view |> form("#ash-quick-action-modal form[phx-submit=save]") |> render_submit()

    box = view |> html() |> LazyHTML.query("#form_brand_id")
    assert LazyHTML.attribute(box, "aria-invalid") == ["true"]
    assert described_by(box) == ["form_brand_id-help", "form_brand_id-errors"]
    assert view |> html() |> LazyHTML.query("#form_brand_id-errors") |> Enum.any?()
  end

  test "names the help before the errors once a save is refused", ctx do
    %{conn: conn, product: product} = ctx

    {:ok, view, _html} = live(conn, ~p"/products/#{product.id}/update")

    view
    |> form("#ash-quick-action-modal form[phx-submit=save]", form: %{sku: "", name: ""})
    |> render_submit()

    html = html(view)
    sku = input(html, "sku")
    [id] = LazyHTML.attribute(sku, "id")

    assert LazyHTML.attribute(sku, "aria-invalid") == ["true"]
    assert described_by(sku) == ["#{id}-help", "#{id}-errors"]
    [name_id] = html |> input("name") |> LazyHTML.attribute("id")
    assert described_by(input(html, "name")) == ["#{name_id}-errors"]
  end

  test "is translated for the reader", %{conn: conn, admin: admin, product: product} do
    arabic = Ash.update!(user(:admin), %{locale: :ar}, actor: admin)
    conn = log_in(conn, arabic)

    {:ok, view, _html} = live(conn, ~p"/products/create")
    helps = helps(view)
    assert "قبل الضريبة." in helps
    assert "الجهة المصنّعة، كما هي مطبوعة على العلبة." in helps

    {:ok, view, _html} = live(conn, ~p"/products/#{product.id}/update")
    assert "تغييره يُبطل الملصقات المطبوعة من قبل." in helps(view)

    {:ok, view, _html} = live(conn, ~p"/products/#{product.id}/reprice")
    assert helps(view) == ["السعر الجديد، قبل الضريبة."]
  end
end
