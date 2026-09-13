defmodule AshQuick.LiveView.ImpersonationTest do
  @moduledoc """
  The event names a host's markup dispatches.

  These are a contract with `assets/js/ash_quick/impersonation.js`, and the
  other half of it is in a language no Elixir test loads. A rename here goes
  unnoticed until a control silently stops working in somebody's browser —
  which is the whole reason these commands exist rather than the strings being
  written into markup.
  """
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.Impersonation

  test "ending an impersonation dispatches the event the client ends on" do
    assert %Phoenix.LiveView.JS{ops: [["dispatch", %{event: event}]]} =
             Impersonation.end_impersonation()

    assert event == "ash_quick:end-impersonation"
  end

  test "clearing one dispatches the event a sign-out link drops it with" do
    assert %Phoenix.LiveView.JS{ops: [["dispatch", %{event: event}]]} =
             Impersonation.clear_impersonation()

    assert event == "ash_quick:clear-impersonation"
  end

  test "both compose onto a command that was already going to run" do
    js = Phoenix.LiveView.JS.push("save")

    assert %Phoenix.LiveView.JS{ops: [["push", _], ["dispatch", %{event: event}]]} =
             Impersonation.clear_impersonation(js)

    assert event == "ash_quick:clear-impersonation"
  end
end
