defmodule AshQuick.LiveView.ExportUtilsTest do
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.ExportUtils

  describe "neutralize/1" do
    test "writes a cell that starts like a formula behind a quote" do
      for text <- ["=1+1", "+cmd|' /C calc'!A0", "-2+3", "@SUM(A1:A2)", "\t=1", "\r=1"] do
        assert ExportUtils.neutralize(text) == "'" <> text
      end
    end

    test "leaves a number alone, signed or not" do
      for text <- ["-5", "+5", "-5.25", "+1.0e3", "42"] do
        assert ExportUtils.neutralize(text) == text
      end
    end

    test "leaves ordinary text alone, wherever a trigger sits past its start" do
      for text <- ["", "Tent", "a=b", "x@example.test", "5-3", " =1"] do
        assert ExportUtils.neutralize(text) == text
      end
    end
  end
end
