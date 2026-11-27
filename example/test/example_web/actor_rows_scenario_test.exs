defmodule ExampleWeb.ActorRowsScenarioTest do
  @moduledoc """
  A form's sub-forms over managed relationships, a `has_many` list and a
  `has_one` row, are built with the page's actor, on create and on update.
  The rows' policies authorize only an actor and their changes refuse a
  changeset without one, so a sub-form built without it would show the error
  and refuse the save.
  """
  use ExampleWeb.FeatureCase, async: true

  require Ash.Query

  alias Example.Test.ActorRows
  alias Example.Test.ActorRows.Keeper
  alias Example.Test.ActorRows.Line

  @modal "#ash-quick-action-modal"

  test "a create saves its new rows as the actor", %{conn: conn, editor: editor} do
    code = unique("ACTOR-")

    conn
    |> log_in(editor)
    |> visit("/test/actor_rows/create")
    |> fill_in(~s(#{@modal} [name="form[code]"]), "Code", with: code)
    |> click_button("#{@modal} button", "Add")
    |> fill_in(~s(#{@modal} [name="form[lines][0][note]"]), "Note", with: "line")
    |> fill_in(~s(#{@modal} [name="form[keeper][note]"]), "Note", with: "keeper")
    |> refute_has(@modal, text: "needs an actor")
    |> click_button("#{@modal} button", "Save")
    |> refute_has("#flash-error")

    record = ActorRows |> Ash.Query.filter(code == ^code) |> Ash.read_one!(authorize?: false)

    assert [%{note: "line", made_by: made_by}] = lines_of(record)
    assert made_by == editor.id
    assert %{note: "keeper", made_by: ^made_by} = keeper_of(record)
  end

  test "an update saves its stored and new rows as the actor", %{conn: conn, editor: editor} do
    record =
      ActorRows
      |> Ash.Changeset.for_create(:create, %{
        code: unique("ACTOR-"),
        lines: [%{note: "a"}],
        keeper: %{note: "kept"}
      })
      |> Ash.create!(actor: editor)

    conn
    |> log_in(editor)
    |> visit("/test/actor_rows/#{record.id}/update")
    |> fill_in(~s(#{@modal} [name="form[lines][0][note]"]), "Note", with: "a2")
    |> click_button("#{@modal} button", "Add")
    |> fill_in(~s(#{@modal} [name="form[lines][1][note]"]), "Note", with: "b")
    |> fill_in(~s(#{@modal} [name="form[keeper][note]"]), "Note", with: "kept2")
    |> refute_has(@modal, text: "needs an actor")
    |> click_button("#{@modal} button", "Save")
    |> refute_has("#flash-error")

    assert [%{note: "a2", made_by: id}, %{note: "b", made_by: id}] = lines_of(record)
    assert id == editor.id
    assert %{note: "kept2", made_by: ^id} = keeper_of(record)
  end

  defp lines_of(record) do
    Line
    |> Ash.Query.filter(actor_rows_id == ^record.id)
    |> Ash.Query.sort(note: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp keeper_of(record) do
    Keeper |> Ash.Query.filter(actor_rows_id == ^record.id) |> Ash.read_one!(authorize?: false)
  end
end
