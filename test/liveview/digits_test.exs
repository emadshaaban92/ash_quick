defmodule AshQuick.LiveView.DigitsTest do
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.Components.FilterForm
  alias AshQuick.LiveView.Digits

  describe "Digits.normalize/1" do
    test "reads Arabic-Indic and Persian digits and Arabic separators as ASCII" do
      assert Digits.normalize("١٢٣") == "123"
      assert Digits.normalize("۴۵۶") == "456"
      assert Digits.normalize("١٬٢٣٤٫٥") == "1234.5"
      assert Digits.normalize("١،٥") == "1,5"
    end

    test "passes anything else through as typed" do
      assert Digits.normalize(" 12a,5 ") == " 12a,5 "
      assert Digits.normalize("") == ""
    end
  end

  describe "a number typed into a filter row" do
    test "is read in ASCII digits, trimmed" do
      assert FilterForm.typed_number(" ١٢٣ ", Ash.Type.Integer) == "123"
      assert FilterForm.typed_number("٣٫٥", Ash.Type.Decimal) == "3.5"
      assert FilterForm.typed_number("١،٥", Ash.Type.Decimal) == "1.5"
    end

    # How a `Money` row's value is read: its digits, with its currency kept.
    test "keeps the currency a Money amount is typed with" do
      assert FilterForm.typed_number("EUR ١٠", Ash.Type.Decimal) == "EUR 10"
      assert FilterForm.typed_number("١٠٫٥ USD", Ash.Type.Decimal) == "10.5 USD"
    end

    # A decimal comma, where nothing else could be meant by it.
    test "reads a decimal comma as a point on a field taking a fraction" do
      assert FilterForm.typed_number("1,5", Ash.Type.Decimal) == "1.5"
      assert FilterForm.typed_number("-12,25", Ash.Type.Float) == "-12.25"
      assert FilterForm.typed_number("0,1234", Ash.Type.Decimal) == "0.1234"
    end

    # `1,000` could be a thousand, and an integer takes no fraction, so the
    # field refuses either as typed rather than reading another number.
    test "leaves a comma that could group thousands, or on an integer, as typed" do
      assert FilterForm.typed_number("1,000", Ash.Type.Decimal) == "1,000"
      assert FilterForm.typed_number("1,5", Ash.Type.Integer) == "1,5"
      assert FilterForm.typed_number("1.000,5", Ash.Type.Decimal) == "1.000,5"
    end
  end

  # iOS's number keyboards have no minus key, so a field that may hold a
  # negative value keeps the full keyboard.
  describe "the keyboard a number asks a phone for" do
    test "is the number keyboard only where the value cannot be negative" do
      assert FilterForm.number_inputmode(%{type: Ash.Type.Integer, constraints: [min: 0]}) ==
               "numeric"

      assert FilterForm.number_inputmode(%{
               type: Ash.Type.Decimal,
               constraints: [min: Decimal.new("0.5")]
             }) == "decimal"

      assert FilterForm.number_inputmode(%{type: Ash.Type.Float, constraints: [min: 1.0]}) ==
               "decimal"

      assert FilterForm.number_inputmode(%{type: Ash.Type.Integer, constraints: []}) == nil
      assert FilterForm.number_inputmode(%{type: Ash.Type.Integer, constraints: [min: -5]}) == nil
      assert FilterForm.number_inputmode(%{type: Ash.Type.String, constraints: []}) == nil
    end
  end
end
