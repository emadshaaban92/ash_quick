defmodule ExampleWeb.FormHelpScenarioTest do
  @moduledoc """
  The help text under a form input: a field's Ash `description`, or the
  `help` its resource declares in place of it, in the reader's language, and
  named by the input's `aria-describedby` beside its errors.

  `Example.Catalog.Product` describes `:sku` and `:brand`, describes `:price`
  for an API's readers and declares the form's help over it, and describes
  nothing else.
  """
  use ExampleWeb.FeatureCase, async: true

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
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

  defp helps(html),
    do: html |> LazyHTML.query("[data-field-help]") |> Enum.map(&LazyHTML.text/1)

  test "draws a description under its input, which names it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/products/create")
    html = html(view)
    sku = input(html, "sku")

    [help_id] = described_by(sku)
    assert help_id == "#{LazyHTML.attribute(sku, "id") |> hd()}-help"
    assert help(html, help_id) =~ "Your own stock code. Unique within a store."
  end

  test "draws the declared help in place of a description", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/products/create")
    helps = view |> html() |> helps() |> Enum.map(&String.trim/1)

    assert "Before tax." in helps
    refute Enum.any?(helps, &(&1 =~ "minor units"))
  end

  # LiveSelect leaves no hook on its text box for an `aria-describedby`.
  test "draws a relationship's description under its dropdown", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/products/create")
    helps = view |> html() |> helps() |> Enum.map(&String.trim/1)

    assert "Who makes it, as printed on the box." in helps
  end

  test "draws nothing for a field with no description", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/products/create")
    html = html(view)

    assert described_by(input(html, "name")) == []
    assert Enum.count(helps(html)) == 3
  end

  test "names the help before the errors once a save is refused", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/products/create")

    view
    |> form("#product-create", form: %{sku: "", name: ""})
    |> render_submit()

    html = html(view)
    sku = input(html, "sku")
    [id] = LazyHTML.attribute(sku, "id")

    assert LazyHTML.attribute(sku, "aria-invalid") == ["true"]
    assert described_by(sku) == ["#{id}-help", "#{id}-errors"]
    [name_id] = html |> input("name") |> LazyHTML.attribute("id")
    assert described_by(input(html, "name")) == ["#{name_id}-errors"]
  end

  test "is translated for the reader", %{conn: conn, admin: admin} do
    arabic = Ash.update!(user(:admin), %{locale: :ar}, actor: admin)
    {:ok, view, _html} = live(log_in(conn, arabic), ~p"/products/create")
    helps = view |> html() |> helps() |> Enum.map(&String.trim/1)

    assert "قبل الضريبة." in helps
    assert "رمز المخزون الخاص بك. لا يتكرر داخل المتجر الواحد." in helps
  end
end
