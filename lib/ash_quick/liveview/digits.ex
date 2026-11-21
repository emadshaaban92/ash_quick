defmodule AshQuick.LiveView.Digits do
  @moduledoc false
  # A number as typed on a phone or keyboard set to Arabic or Persian, as
  # the digits and point Ash reads: Arabic-Indic digits, `١٢٣`, and Eastern
  # Arabic-Indic ones, `۱۲۳`, as `0` to `9`, the Arabic decimal separator
  # `٫` as `.`, the Arabic thousands separator `٬` dropped, and the Arabic
  # comma `،` as `,`, which a list of values or a decimal comma is typed
  # with. Anything else is passed through as typed.

  @doc "`value` with its Arabic and Persian digits and separators as ASCII."
  def normalize(value) when is_binary(value) do
    value
    |> String.replace(~r/[\x{0660}-\x{0669}]/u, &digit(&1, 0x0660))
    |> String.replace(~r/[\x{06F0}-\x{06F9}]/u, &digit(&1, 0x06F0))
    |> String.replace("٫", ".")
    |> String.replace("٬", "")
    |> String.replace("،", ",")
  end

  defp digit(<<codepoint::utf8>>, zero), do: Integer.to_string(codepoint - zero)
end
