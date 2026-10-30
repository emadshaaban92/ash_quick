defmodule ExampleWeb.MoneyScenarioTest do
  @moduledoc """
  A `Money` reads on the list, the details page and in an export in the
  reader's locale, the way `AshQuick.Config.format_money/1` formats it.

  The reader is Arabic: an Egyptian pound reads `ج.م.` there, where Money's
  own rendering, in Localize's process locale, reads `EGP`. That needs the
  Arabic data `mix localize.download_locales` fetches (`mix setup` runs it).
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.S3Stub

  # An export is generated in a task that competes with every async case, so
  # `render_async/1`'s 100 ms default is too short; see `ListScenarioTest`.
  @export_timeout to_timeout(second: 5)

  @pound "ج.م."

  setup %{conn: conn, admin: admin} do
    # Without the data Localize formats Arabic in English, and every assertion
    # below would fail for a reason they do not name.
    assert File.exists?(Application.app_dir(:example, "priv/localize/locales/ar.etf")),
           "no Arabic Localize data; run `mix localize.download_locales`"

    arabic = Ash.update!(admin, %{locale: :ar}, actor: admin)
    product = product(price: Money.new(:EGP, "460000"), actor: admin)

    {:ok, conn: log_in(conn, arabic), arabic: arabic, product: product}
  end

  test "the list and the details page write a price in the reader's locale", ctx do
    %{conn: conn, product: product} = ctx

    conn
    |> visit(~p"/products?search=#{product.sku}")
    |> assert_has("td", text: @pound)
    |> assert_has("td", text: "460,000.00")
    |> refute_has("td", text: "EGP")
    |> visit(~p"/products/#{product.id}")
    |> assert_has(~s([data-field="price"] dd), text: @pound)
    |> refute_has(~s([data-field="price"] dd), text: "EGP")
  end

  test "an export writes a price in the reader's locale", ctx do
    %{conn: conn, arabic: arabic, product: product} = ctx

    {:ok, view, _html} = live(conn, ~p"/products?search=#{product.sku}")

    view |> element("a", "CSV") |> render_click()
    render_async(view, @export_timeout)

    csv = exported_csv(arabic)

    assert csv =~ @pound
    refute csv =~ "EGP"
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
