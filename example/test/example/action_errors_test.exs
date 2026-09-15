defmodule Example.ActionErrorsTest do
  @moduledoc """
  What `AshQuick.LiveView.ActionErrors` says in a host that has no Tower.

  `:tower` is an *optional* dependency of the library, and this app does not
  install it — which is exactly the case the library's own suite cannot cover,
  because there Tower is present. Where the report ends up is not the point.
  That the handler keeping a page up does not itself raise is: `report_error/1`
  is reached by every error that is not a recognised one, so a bare call to a
  module the host never installed turns every unexpected failure into a crashed
  LiveView — the opposite of what this module is for.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshQuick.LiveView.ActionErrors

  # The premise the rest of the file rests on. If this app ever picks `:tower`
  # up — directly, or transitively through a dependency — these cases quietly
  # stop testing the thing they were written for, and this is what says so.
  test "this host really does not have Tower" do
    refute Code.ensure_loaded?(Tower)
  end

  test "an unexpected error is reduced to a sentence rather than raising" do
    log =
      capture_log(fn ->
        assert ActionErrors.user_facing_message(%RuntimeError{message: "a detail from inside"}) ==
                 ActionErrors.generic_message()
      end)

    # Reduced for the reader, still recorded for whoever has to fix it.
    assert log =~ "a detail from inside"
  end

  test "so is a framework failure wearing an :invalid class" do
    error =
      Ash.Error.Invalid.exception(
        errors: [Ash.Error.Invalid.TenantRequired.exception(resource: Example.Catalog.Product)]
      )

    log =
      capture_log(fn ->
        assert ActionErrors.user_facing_message(error) == ActionErrors.generic_message()
      end)

    assert log =~ "TenantRequired"
  end

  # The recognised errors never reach the report at all, so they are the control:
  # they would read the same whether or not the fallback above works.
  test "a recognised error is not reported anywhere" do
    log =
      capture_log(fn ->
        assert ActionErrors.user_facing_message(Ash.Error.Forbidden.exception(errors: [])) ==
                 ActionErrors.forbidden_message()
      end)

    assert log == ""
  end
end
