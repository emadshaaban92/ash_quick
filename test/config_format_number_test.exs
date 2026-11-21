defmodule AshQuick.ConfigFormatNumberTest do
  @moduledoc """
  `AshQuick.Config.format_number/1` groups a number in the reader's locale
  and keeps every fractional digit the value holds, where Localize's own
  pattern rounds to three places. A locale Localize holds no data for reads
  the number as Elixir prints it.
  """
  use ExUnit.Case, async: true

  alias AshQuick.Config

  test "groups an integer" do
    assert Config.format_number(1_234_567) == "1,234,567"
    assert Config.format_number(-12_345) == "-12,345"
    assert Config.format_number(0) == "0"
  end

  test "keeps a decimal's scale" do
    assert Config.format_number(Decimal.new("-10.50")) == "-10.50"
    assert Config.format_number(Decimal.new("1234.000")) == "1,234.000"
    assert Config.format_number(Decimal.new("0.123456789")) == "0.123456789"
    assert Config.format_number(Decimal.new("1E+3")) == "1,000"
  end

  test "keeps a float's shortest form" do
    assert Config.format_number(1_234_567.891234) == "1,234,567.891234"
    assert Config.format_number(0.25) == "0.25"
    assert Config.format_number(-2.5) == "-2.5"
  end

  # Localize would write these in English, its fallback: a German reader
  # would take `1,234.5` for a number near one.
  test "leaves a number as Elixir prints it in a locale Localize has no data for" do
    backend = AshQuick.Config.gettext() || AshQuick.Gettext

    for locale <- ["de", "xx"] do
      Gettext.put_locale(backend, locale)

      assert Config.format_number(1_234_567) == "1234567"
      assert Config.format_number(Decimal.new("1234.50")) == "1234.50"
      assert Config.format_number(1234.5) == "1234.5"
    end
  after
    Gettext.put_locale(AshQuick.Config.gettext() || AshQuick.Gettext, "en")
  end

  test "prints infinity and NaN as Decimal does" do
    assert Config.format_number(Decimal.new("Infinity")) == "Infinity"
    assert Config.format_number(Decimal.new("NaN")) == "NaN"
  end
end
