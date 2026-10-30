defmodule AshQuick.ConfigFormatTest do
  @moduledoc """
  `AshQuick.Config` formats dates and money in the reader's locale, the one
  the host's Gettext backend translates in.

  Localize ships English data alone and this suite downloads none, so the
  locale here is English written in Arabic-Indic digits: it reads differently
  from the default with nothing but that data.
  """
  use ExUnit.Case, async: true

  alias AshQuick.Config

  @locale "en-u-nu-arab"

  setup do
    Gettext.put_locale(Config.gettext(), @locale)
    :ok
  end

  test "a date reads in the reader's locale" do
    assert Config.format_date(~D[2026-10-25]) == "Oct ٢٥, ٢٠٢٦"
  end

  test "money reads in the reader's locale" do
    assert Config.format_money(Money.new(:EGP, "460000")) == "٤٦٠٬٠٠٠٫٠٠ EGP"
  end

  test "money in a locale Localize cannot parse reads as Money writes it" do
    Gettext.put_locale(Config.gettext(), "not a locale!")
    assert Config.format_money(Money.new(:EGP, "460000")) == "EGP 460,000.00"
  end
end
