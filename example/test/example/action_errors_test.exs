defmodule Example.ActionErrorsTest do
  @moduledoc """
  Where `AshQuick.LiveView.ActionErrors` sends what it could not explain, in a
  host that has Tower but never configured it.

  `:tower` comes with the library, and this app leaves its `:reporters` at
  Tower's default, `Tower.EphemeralReporter` — the setup a host has before it
  names a reporter. That reporter keeps the last 50 events in memory, which is
  what makes it the place to read a report back from: the person gets a
  sentence, the error itself goes to Tower, and a recognised one goes nowhere.

  Each error carries something unique to its test, so it is told apart from
  whatever the rest of the async suite reports meanwhile.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshQuick.LiveView.ActionErrors

  # The premise the rest of the file rests on. If this app configures a
  # reporter, nothing lands in `Tower.EphemeralReporter.events/0` and the cases
  # below fail on that rather than on what they test.
  test "this host leaves Tower at its default reporter" do
    assert Application.get_env(:tower, :reporters) == [Tower.EphemeralReporter]
  end

  test "an unexpected error is reduced to a sentence and reported to Tower" do
    error = %RuntimeError{message: "a detail from inside #{System.unique_integer()}"}

    log =
      capture_log(fn ->
        assert ActionErrors.user_facing_message(error) == ActionErrors.generic_message()
      end)

    assert [%Tower.Event{kind: :error, level: :error}] = reports_of(error)

    # Tower is where it goes, not the log as well: a host whose Tower
    # `log_level` lets `:error` through would get every one of them twice.
    # Refuted by this error's own text, because `capture_log/1` also catches
    # whatever the rest of the async suite logs meanwhile.
    refute log =~ error.message
  end

  test "so is a framework failure wearing an :invalid class" do
    error =
      Ash.Error.Invalid.exception(
        errors: [Ash.Error.Invalid.TenantRequired.exception(resource: Example.Catalog.Product)],
        vars: [probe: make_ref()]
      )

    assert ActionErrors.user_facing_message(error) == ActionErrors.generic_message()
    assert [%Tower.Event{}] = reports_of(error)
  end

  # The recognised errors never reach the report, so they are the control: they
  # read the same whether or not reporting works.
  test "a recognised error is not reported anywhere" do
    probe = make_ref()
    error = Ash.Error.Forbidden.exception(errors: [], vars: [probe: probe])

    log =
      capture_log(fn ->
        assert ActionErrors.user_facing_message(error) == ActionErrors.forbidden_message()
      end)

    assert reports_of(error) == []
    refute log =~ inspect(probe)
  end

  defp reports_of(error), do: Enum.filter(Tower.EphemeralReporter.events(), &(&1.reason == error))
end
