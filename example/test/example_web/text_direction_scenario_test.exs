defmodule ExampleWeb.TextDirectionScenarioTest do
  @moduledoc """
  A record's name reads in its own direction wherever a page names it: in a
  details page title, a list cell, the bookkeeping line's writer and a
  confirmation. A name of digits and signs, such as a phone number, reads
  left to right on an Arabic page too, and one with letters in the direction
  of its first letter.
  """
  use ExampleWeb.FeatureCase, async: true

  setup %{conn: conn, admin: admin}, do: %{conn: log_in(conn, admin)}

  for {label, name, dir} <- [
        {"a phone number", "+20 100 123 4567", "ltr"},
        {"a Latin name", "Acme Inc.", "auto"}
      ] do
    test "titles #{label} with dir=#{dir}", %{conn: conn, admin: admin} do
      brand =
        Ash.create!(Example.Catalog.Brand, %{code: unique("TD"), name: unquote(name)},
          actor: admin,
          authorize?: false
        )

      {:ok, view, _html} = live(conn, "/brands/#{brand.id}")

      assert has_element?(view, ~s(#details-menus h1 span[dir="#{unquote(dir)}"]), unquote(name))
    end
  end

  @modal "#ash-quick-action-modal"

  describe "a record named by digits and signs" do
    setup %{admin: admin} do
      phone = "+20 #{System.unique_integer([:positive])}"
      brand = brand(name: phone, actor: admin)
      writer = user(:admin, name: phone)
      product = product(name: phone, brand: brand, actor: writer)

      %{phone: phone, product: product}
    end

    test "reads left to right in a list cell", %{conn: conn, phone: phone, product: product} do
      filter =
        %{
          "operator" => "and",
          "children" => [%{"field_name" => "sku", "operator" => "equals", "value" => product.sku}]
        }
        |> JSON.encode!()
        |> :base64.encode()
        |> URI.encode_www_form()

      {:ok, view, _html} = live(conn, "/products?custom_filter=#{filter}")

      assert has_element?(view, ~s(tr[id="#{product.id}"] td a span[dir="ltr"]), phone)
    end

    test "reads left to right as the writer, linked or not", ctx do
      %{conn: conn, editor: editor, phone: phone, product: product} = ctx

      # The admin reaches `/users`, so the writer is a link; an editor does not.
      {:ok, view, _html} = live(conn, "/products/#{product.id}")
      assert has_element?(view, ~s(header p a span[dir="ltr"]), phone)

      {:ok, view, _html} = conn |> log_in(editor) |> live("/products/#{product.id}")
      refute has_element?(view, ~s(header p a span[dir="ltr"]), phone)
      assert has_element?(view, ~s(header p span[dir="ltr"]), phone)
    end

    test "reads left to right in a confirmation", %{conn: conn, phone: phone, product: product} do
      {:ok, view, _html} = live(conn, "/products/#{product.id}/deactivate")

      assert has_element?(view, ~s(#{@modal} p span[dir="ltr"]), phone)
    end
  end
end
