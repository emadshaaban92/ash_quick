defmodule ExampleWeb.UnseenKeeperScenarioTest do
  @moduledoc """
  A belongs-to whose record the reader may not see is drawn as unavailable,
  and keeps its key: an update that leaves it alone saves it as it was.

  `Example.Test.UnseenKeepers` is kept by a keeper that only an admin sees.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.UnseenKeepers
  alias Example.Test.UnseenKeepers.Keeper
  alias ExampleWeb.PickerDriver, as: Picker

  setup %{admin: admin} do
    hidden = Ash.create!(Keeper, %{name: unique("Hidden"), hidden: true}, actor: admin)
    shown = Ash.create!(Keeper, %{name: unique("Shown")}, actor: admin)
    record = Ash.create!(UnseenKeepers, %{code: unique("K"), keeper_id: hidden.id})

    %{hidden: hidden, shown: shown, record: record}
  end

  test "an update keeps the key of a keeper the reader can't see", ctx do
    %{conn: conn, admin: admin, hidden: hidden, record: record} = ctx
    conn = log_in(conn, user(:editor, actor: admin))
    {:ok, view, _html} = live(conn, "/test/unseen_keepers/#{record.id}/update")

    assert Picker.picked(view, "form_keeper_id-picker") == ["Unavailable"]
    refute render(view) =~ hidden.name
    assert Picker.posted(view, "form_keeper_id-picker") == [{"form[keeper_id]", hidden.id}]
    refute hidden.name in Picker.search(view, "form_keeper_id-picker")

    view
    |> form("form[phx-submit=save]", form: %{note: "Checked"})
    |> render_submit()

    assert %{note: "Checked", keeper_id: keeper_id} =
             Ash.get!(UnseenKeepers, record.id, authorize?: false)

    assert keeper_id == hidden.id
  end

  test "an admin sees the keeper by name", ctx do
    %{conn: conn, admin: admin, hidden: hidden, record: record} = ctx
    {:ok, view, _html} = conn |> log_in(admin) |> live("/test/unseen_keepers/#{record.id}/update")

    assert Picker.picked(view, "form_keeper_id-picker") == [hidden.name]
  end

  test "the reader can still change it to one they see", ctx do
    %{conn: conn, admin: admin, shown: shown, record: record} = ctx
    conn = log_in(conn, user(:editor, actor: admin))
    {:ok, view, _html} = live(conn, "/test/unseen_keepers/#{record.id}/update")

    Picker.search(view, "form_keeper_id-picker", shown.name)
    Picker.pick(view, "form_keeper_id-picker", shown.name)
    view |> form("form[phx-submit=save]") |> render_submit()

    assert Ash.get!(UnseenKeepers, record.id, authorize?: false).keeper_id == shown.id
  end
end
