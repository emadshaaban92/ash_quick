defmodule AshQuick.ComponentsTranslateErrorTest do
  @moduledoc """
  What an error beside a form input says when the host configures no
  `:error_translator` of its own.

  The tuple is the one AshPhoenix files under the field, vars and all — and
  `validate match/2` always puts its `%Regex{}` among them, which has no
  `String.Chars`.
  """
  use ExUnit.Case, async: true

  alias AshQuick.Components

  test "a match/2 message renders without touching the regex it never names" do
    assert Components.translate_error({"must be digits", [field: :code, match: ~r/^\d+$/]}) ==
             "must be digits"
  end

  test "a named var with no String.Chars renders through inspect" do
    assert Components.translate_error({"must match %{match}", [match: ~r/^\d+$/]}) ==
             ~S"must match ~r/^\d+$/"
  end

  test "a named var with String.Chars is interpolated as before" do
    assert Components.translate_error({"should be at least %{count} characters", [count: 3]}) ==
             "should be at least 3 characters"
  end
end
