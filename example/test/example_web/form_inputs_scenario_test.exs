defmodule ExampleWeb.FormInputsScenarioTest do
  @moduledoc """
  A form draws a field by its type when `config :ash_quick, form_inputs:`
  names one, or AshQuick does: a `Money` as an amount beside its currency.

  `config/test.exs` names `Example.Test.FormInputs.PhoneInput` for a phone,
  `PhonesInput` for a list of them, and `false` for the plain-text
  `PlainPrice`. `Example.Test.FormInputs` holds the fields. Only this test
  writes to its table.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.FormInputs

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  describe "a Money field" do
    test "is an amount beside a currency select, or the code when one is allowed", %{conn: conn} do
      conn
      |> visit(~p"/test/form_inputs/create")
      # No `only`: the current currencies, starting at the reader's locale's.
      |> assert_has("input[name='form[price][amount]'][type='text'][dir='ltr']")
      # Lined up with the other inputs on a right-to-left page, its class
      # joining the box's own rather than standing as a second attribute.
      |> assert_has("input[name='form[price][amount]'].input.rtl\\:text-right")
      |> refute_has("input[name='form[price][amount]'][inputmode]")
      |> assert_has("select[name='form[price][currency]'] option[selected]", text: "USD")
      |> assert_has("select[name='form[price][currency]'] option", text: "EGP")
      # One currency is nothing to pick.
      |> refute_has("select[name='form[fee][currency]']")
      |> assert_has("#form_fee_currency", text: "EGP")
      |> assert_has("input[type='hidden'][name='form[fee][currency]'][value='EGP']")
      |> assert_has("label[for='form_fee_amount']", text: "Fee")
      # The amount box names the fixed code, between its help and errors.
      |> assert_has("#form_fee_amount[aria-describedby='form_fee_currency']")
      # Each select is named after its field.
      |> assert_has("label.sr-only[for='form_price_currency']", text: "Price currency")
      |> assert_has("label.sr-only[for='form_tip_currency']", text: "Tip currency")
      |> refute_has("select[name='form[price][currency]'] option[value='XXX']")
      |> refute_has("select[name='form[price][currency]'] option[value='XAU']")
      # A NewType of Money: its `only`, starting at its `default_currency`.
      |> assert_has("select[name='form[tip][currency]'] option[selected]", text: "EUR")
      |> assert_has("select[name='form[tip][currency]'] option", count: 2)
      # One the config turns off is typed as one string.
      |> assert_has("input[name='form[plain]'][type='text']")
      |> refute_has("input[name='form[plain][amount]']")
      # And inside an embed's sub-form, which a page's widgets never reach.
      |> assert_has("select[name='form[box][deposit][currency]'] option", count: 2)
    end

    test "saves the amount in the currency picked, reading Arabic digits", %{conn: conn} do
      code = unique("M")

      conn
      |> visit(~p"/test/form_inputs/create")
      |> fill_in("Code", with: code)
      |> fill_in("Price", with: "١٢,٥")
      |> select("#form_price_currency", "Price currency", option: "EGP")
      |> fill_in("Fee", with: "3")
      |> fill_in("Tip", with: "2.50")
      |> fill_in("Plain", with: "USD 7")
      |> click_button("Save")
      |> refute_has("#flash-error")

      saved = saved(code)
      assert Money.equal?(saved.price, Money.new(:EGP, "12.5"))
      assert Money.equal?(saved.fee, Money.new(:EGP, "3"))
      assert Money.equal?(saved.tip, Money.new(:EUR, "2.50"))
      assert Money.equal?(saved.plain, Money.new(:USD, "7"))
    end

    test "shows the held amount and currency, and saves them back untouched", %{conn: conn} do
      record = form_input(price: Money.new(:EUR, "1234.5"), tip: Money.new(:USD, "1"))

      conn
      |> visit(~p"/test/form_inputs/#{record.id}/update")
      |> assert_has("input[name='form[price][amount]'][value='1234.5']")
      |> assert_has("select[name='form[price][currency]'] option[selected]", text: "EUR")
      |> assert_has("select[name='form[tip][currency]'] option[selected]", text: "USD")
      |> click_button("Save")
      |> refute_has("#flash-error")

      saved = Ash.reload!(record, authorize?: false)
      assert Money.equal?(saved.price, Money.new(:EUR, "1234.5"))
      assert Money.equal?(saved.tip, Money.new(:USD, "1"))
    end

    # The fixed currency posts from a hidden input, which LiveView never marks
    # unused: it must not count as touching the field.
    test "says a required amount is missing only once it is used or saved", %{conn: conn} do
      conn
      |> visit(~p"/test/form_inputs/create")
      |> fill_in("Code", with: unique("M"))
      |> refute_has("#form_fee-errors")
      |> click_button("Save")
      |> assert_has("#form_fee-errors", text: "is required")
      |> assert_has("#form_fee_amount[aria-describedby='form_fee_currency form_fee-errors']")
    end

    test "keeps the currency picked when the amount is cleared", %{conn: conn} do
      conn
      |> visit(~p"/test/form_inputs/create")
      |> fill_in("Price", with: "5")
      |> select("#form_price_currency", "Price currency", option: "EGP")
      |> fill_in("Price", with: "")
      |> assert_has("select[name='form[price][currency]'] option[selected]", text: "EGP")
    end

    test "lets Ash refuse an amount it cannot read", %{conn: conn} do
      conn
      |> visit(~p"/test/form_inputs/create")
      |> fill_in("Code", with: unique("M"))
      |> fill_in("Fee", with: "lots")
      |> fill_in("Price", with: "lots")
      |> click_button("Save")
      |> assert_has("#form_fee-errors")
      |> assert_has("#form_price-errors")
      |> assert_has("#form_price_currency[aria-invalid='true']")
    end
  end

  describe "a type the config names" do
    test "is drawn by the host's input, everywhere but where the page or sensitive? says", %{
      conn: conn
    } do
      conn
      |> visit(~p"/test/form_inputs/create")
      |> assert_has("input[data-phone-input][type='tel'][name='form[phone]']")
      |> assert_has("input[data-phone-input][name='form[box][phone]']")
      |> assert_has("[data-phones-input] input[type='tel'][name='form[phones][]']")
      # The page's widget wins.
      |> assert_has("input[data-widget][name='form[alt_phone]']")
      |> refute_has("input[data-phone-input][name='form[alt_phone]']")
      # A sensitive field keeps its password input, which shows no value.
      |> assert_has("input[type='password'][name='form[secret_phone]']")
    end

    test "saves what the host's input posts", %{conn: conn} do
      code = unique("M")

      conn
      |> visit(~p"/test/form_inputs/create")
      |> fill_in("Code", with: code)
      |> fill_in("Fee", with: "1")
      |> fill_in("#form_phone", "Phone", with: "+20 100 000 0000")
      |> click_button("Save")
      |> refute_has("#flash-error")

      assert saved(code).phone == "+20 100 000 0000"
    end

    test "can save a list, which the page counts as saveable", %{conn: conn} do
      record = form_input(phones: ["111", "222"])

      conn
      |> visit(~p"/test/form_inputs/#{record.id}/update")
      |> assert_has("[data-phones-input] input[value='111']")
      |> assert_has("[data-phones-input] input[value='222']")
      |> click_button("Save")
      |> refute_has("#flash-error")

      assert Ash.reload!(record, authorize?: false).phones == ["111", "222"]
    end
  end

  defp saved(code) do
    FormInputs |> Ash.read!(authorize?: false) |> Enum.find(&(&1.code == code))
  end

  defp form_input(attrs) do
    Ash.create!(
      FormInputs,
      Map.merge(%{code: unique("M"), fee: Money.new(:EGP, "1")}, Map.new(attrs)),
      authorize?: false
    )
  end
end
