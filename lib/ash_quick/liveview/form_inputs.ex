defmodule AshQuick.LiveView.FormInputs do
  @moduledoc false
  # What a form's generic input (`FormView.field_input/1`'s last clause) is
  # drawn as, from the field's Ash type and constraints. Every attribute here
  # is a hint for the browser; Ash still casts and validates what is posted.
  #
  # Numbers stay `type="text"`. A `type="number"` input empties a value it
  # cannot parse, so the server would answer "required" rather than
  # "invalid", the scroll wheel changes it, and browsers differ on the digits
  # it takes. `inputmode` brings up a phone's number pad instead, and
  # `AshQuick.LiveView.FormParams` turns Arabic-Indic and Persian digits into
  # 0-9 on the way in. A phone's number pad may have no minus key, so a field
  # whose constraints allow a negative value keeps the full keyboard.
  #
  # Dates and times get the browser's picker, which always posts 0-9 digits.
  # They name no zone, as the types hold none. A time held to the microsecond
  # stays text: a time input carries milliseconds at most, so an untouched
  # one would post back a different value.

  alias Ash.Type.NewType

  @doc false
  def attrs(%{type: type, constraints: constraints}, value) do
    {base, constraints} = base(type, constraints)
    attrs(base, constraints || [], value)
  end

  # `:integer` or `:fraction` for a field that holds a number, whose posted
  # value `FormParams.normalize_digits/3` reads as Ash reads one, `:money` for
  # a `Money`, whose posted amount it reads as a fraction, else nil.
  @doc false
  def number_kind(%{type: type, constraints: constraints}) do
    case base(type, constraints) do
      {Ash.Type.Integer, _constraints} -> :integer
      {type, _constraints} when type in [Ash.Type.Float, Ash.Type.Decimal] -> :fraction
      {AshMoney.Types.Money, _constraints} -> :money
      _ -> nil
    end
  end

  defp base(type, constraints) do
    if NewType.new_type?(type) do
      {NewType.subtype_of(type), NewType.constraints(type, constraints || [])}
    else
      {type, constraints}
    end
  end

  defp attrs(Ash.Type.Integer, constraints, _value), do: number(constraints, "numeric")

  defp attrs(type, constraints, _value) when type in [Ash.Type.Float, Ash.Type.Decimal],
    do: number(constraints, "decimal")

  defp attrs(Ash.Type.Date, _constraints, _value), do: [type: "date"]

  defp attrs(Ash.Type.Time, constraints, _value) do
    if Keyword.get(constraints, :precision, :second) == :second,
      do: [type: "time", step: "1"],
      else: []
  end

  # A naive datetime is held to the second, which `datetime-local` shows only
  # with a `step` under a minute and a value carrying the seconds: Phoenix's
  # own rendering of one cuts them off.
  defp attrs(Ash.Type.NaiveDatetime, _constraints, value) do
    [type: "datetime-local", step: "1"] ++ naive_value(value)
  end

  defp attrs(type, constraints, _value) when type in [Ash.Type.String, Ash.Type.CiString],
    do: lengths(constraints)

  defp attrs(_type, _constraints, _value), do: []

  # Digits and a sign read left to right inside a right-to-left page too: a
  # bare minus would otherwise land after the number. The value still lines
  # up with the page's other inputs, on the right of a right-to-left page.
  defp number(constraints, mode) do
    rtl = [dir: "ltr", class: "rtl:text-right"]
    if negative_allowed?(constraints), do: rtl, else: [inputmode: mode] ++ rtl
  end

  defp negative_allowed?(constraints) do
    not (at_least_zero?(constraints[:min]) or at_least_zero?(constraints[:greater_than]))
  end

  defp at_least_zero?(nil), do: false
  defp at_least_zero?(%Decimal{} = bound), do: not Decimal.negative?(bound)
  defp at_least_zero?(bound) when is_number(bound), do: bound >= 0

  defp at_least_zero?(bound) when is_binary(bound) do
    case Decimal.parse(bound) do
      {decimal, ""} -> at_least_zero?(decimal)
      _ -> false
    end
  end

  defp at_least_zero?(_bound), do: false

  defp naive_value(%NaiveDateTime{} = value) do
    [value: value |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()]
  end

  defp naive_value(_value), do: []

  # `minlength` from `min_length`, where a browser's count is never under
  # Ash's. It counts UTF-16 code units, one per code point and two for one
  # past U+FFFF: never under Ash's graphemes or code points, but under its
  # bytes. It counts the value untrimmed too, which only makes it laxer than
  # Ash's check on the trimmed one. No `maxlength`: a browser stops typing, and cuts a
  # pasted value short without a word, at its own count of the untrimmed
  # value, so `"  ABCDEFGHIJ"` under a limit of 10 would be saved as
  # `"ABCDEFGH"`. Ash's error under the input says when a value is too long.
  defp lengths(constraints) do
    if constraints[:min_length] &&
         Ash.Type.String.length_count(constraints) in [:graphemes, :codepoints],
       do: [minlength: constraints[:min_length]],
       else: []
  end
end
