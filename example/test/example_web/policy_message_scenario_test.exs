defmodule ExampleWeb.PolicyMessageScenarioTest do
  @moduledoc """
  A run a policy refuses says the policy's `error_message` when it has one, and
  the fixed sentence when it has none.

  `Example.Test.WordedPolicy` refuses each case at the run, not before the
  modal opens: a refusal the page can see coming never reaches a run, so it has
  no policy error to word.
  """
  use ExampleWeb.FeatureCase, async: true

  @bulk "a[phx-click*='bulk_action']"
  @modal "#ash-quick-action-modal"

  test "a form the run refuses says the policy's message", %{conn: conn, admin: admin} do
    record = worded(unique("open-"))

    conn
    |> log_in(admin)
    |> visit("/test/worded_policy/#{record.id}/rename")
    |> fill_in("Code", with: "locked")
    |> click_button("Save")
    |> assert_has("#flash-error", text: "No record may be renamed to locked.")
    |> refute_has("#flash-error", text: AshQuick.LiveView.ActionErrors.forbidden_message())

    assert Ash.get!(Example.Test.WordedPolicy, record.id, authorize?: false).code == record.code
  end

  test "a bulk run it refuses says the policy's message", %{conn: conn, admin: admin} do
    record = worded(unique("sealed-"))

    conn
    |> log_in(admin)
    |> visit("/test/worded_policy")
    |> tick_rows([record.id])
    |> click_link(@bulk, "Seal")
    |> click_button("#{@modal} button", "Confirm")
    |> assert_has("#flash-error", text: "Sealing is closed for the season.")

    refute Ash.get!(Example.Test.WordedPolicy, record.id, authorize?: false).sealed
  end

  test "a policy with no message of its own gets the fixed sentence", ctx do
    %{conn: conn, admin: admin} = ctx
    record = worded(unique("stamped-"))

    conn
    |> log_in(admin)
    |> visit("/test/worded_policy")
    |> tick_rows([record.id])
    |> click_link(@bulk, "Stamp")
    |> click_button("#{@modal} button", "Confirm")
    |> assert_has("#flash-error", text: AshQuick.LiveView.ActionErrors.forbidden_message())

    refute Ash.get!(Example.Test.WordedPolicy, record.id, authorize?: false).sealed
  end

  defp worded(code) do
    Example.Test.WordedPolicy
    |> Ash.Changeset.for_create(:create, %{code: code})
    |> Ash.create!(authorize?: false)
  end
end
