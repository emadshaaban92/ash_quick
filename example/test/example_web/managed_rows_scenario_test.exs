defmodule ExampleWeb.ManagedRowsScenarioTest do
  @moduledoc """
  An update form over a `has_many` its action manages with `direct_control`
  draws one sub-form per stored row. A plain save keeps every row, and an
  edited row updates its own record, keeping what its sub-form does not draw
  or the page disables. The same holds for rows a row's own update manages,
  for a managed relationship that points back up the chain, and for a
  `many_to_many` whose join carries an attribute.
  """
  use ExampleWeb.FeatureCase, async: true

  require Ash.Query

  alias Example.Test.ManagedNest
  alias Example.Test.ManagedRows
  alias Example.Test.ManagedRows.Row
  alias Example.Test.ManagedRows.Tag
  alias Example.Test.ManagedRows.Tagging
  alias Example.Test.ManagedRows.Item

  @modal "#ash-quick-action-modal"

  setup do
    record =
      ManagedRows
      |> Ash.Changeset.for_create(:create, %{
        code: unique("ROWS-"),
        items: [
          %{status: "a", note: "keep", secret: "first"},
          %{status: "b", note: "also", secret: "second"}
        ]
      })
      |> Ash.create!(authorize?: false)

    %{record: record, stored: items_of(record)}
  end

  test "draws a sub-form per stored row", %{conn: conn, editor: editor, record: record} do
    conn
    |> log_in(editor)
    |> visit("/test/managed_rows/#{record.id}/update")
    |> assert_has(~s(#{@modal} [name="form[items][0][status]"][value="a"]))
    |> assert_has(~s(#{@modal} [name="form[items][0][note]"][value="keep"]))
    |> assert_has(~s(#{@modal} [name="form[items][1][status]"][value="b"]))
    |> refute_has(~s(#{@modal} [name="form[items][0][secret]"]))
  end

  test "a plain save keeps every stored row", ctx do
    %{conn: conn, editor: editor, record: record, stored: stored} = ctx

    conn
    |> log_in(editor)
    |> visit("/test/managed_rows/#{record.id}/update")
    |> click_button("#{@modal} button", "Save")
    |> refute_has("#flash-error")

    assert items_of(record) == stored
  end

  test "an edited row updates its own record", ctx do
    %{conn: conn, editor: editor, record: record, stored: [first, second]} = ctx

    conn
    |> log_in(editor)
    |> visit("/test/managed_rows/#{record.id}/update")
    |> fill_in(~s(#{@modal} [name="form[items][0][note]"]), "Note", with: "changed")
    |> click_button("#{@modal} button", "Save")
    |> refute_has("#flash-error")

    assert [edited, ^second] = items_of(record)
    assert edited.id == first.id
    assert edited.note == "changed"
    assert edited.secret == "first"
  end

  test "a removed row is destroyed, and an added one created", ctx do
    %{conn: conn, editor: editor, record: record, stored: [first, _second]} = ctx

    conn
    |> log_in(editor)
    |> visit("/test/managed_rows/#{record.id}/update")
    |> click_button(~s(#{@modal} [phx-click="remove-form"][phx-value-path="form[items][1]"]), "")
    |> click_button("#{@modal} button", "Add")
    |> fill_in(~s(#{@modal} [name="form[items][1][status]"]), "Status", with: "c")
    |> click_button("#{@modal} button", "Save")
    |> refute_has("#flash-error")

    assert [^first, added] = items_of(record)
    assert added.status == "c"
  end

  test "a row's field the page disables keeps its stored value", ctx do
    %{conn: conn, editor: editor, record: record, stored: [first, second]} = ctx

    conn
    |> log_in(editor)
    |> visit("/test/managed_rows_held/#{record.id}/update")
    |> assert_has(~s(#{@modal} [data-disabled-field="note"]), text: "keep")
    |> refute_has(~s(#{@modal} [name="form[items][0][note]"]))
    |> fill_in(~s(#{@modal} [name="form[items][0][status]"]), "Status", with: "a2")
    |> click_button("#{@modal} button", "Save")
    |> refute_has("#flash-error")

    assert [edited, ^second] = items_of(record)
    assert edited.id == first.id
    assert edited.status == "a2"
    assert edited.note == "keep"
    assert edited.secret == "first"
  end

  test "a host load that narrows the rows still draws and keeps every field", ctx do
    %{conn: conn, editor: editor, record: record, stored: stored} = ctx

    conn
    |> log_in(editor)
    |> visit("/test/managed_rows_narrow/#{record.id}/update")
    |> assert_has(~s(#{@modal} [name="form[items][0][note]"][value="keep"]))
    |> click_button("#{@modal} button", "Save")
    |> refute_has("#flash-error")

    assert items_of(record) == stored
  end

  describe "nested and many_to_many rows" do
    setup do
      [light, heavy] =
        Enum.map(~w(light heavy), fn name ->
          Tag |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create!()
        end)

      nest =
        ManagedNest
        |> Ash.Changeset.for_create(:create, %{
          code: unique("NEST-"),
          rows: [%{status: "a", parts: [%{label: "p1"}, %{label: "p2"}]}]
        })
        |> Ash.create!(authorize?: false)

      for {tag, weight} <- [{heavy, 5}, {light, 1}] do
        Tagging
        |> Ash.Changeset.for_create(:create, %{weight: weight})
        |> Ash.Changeset.force_change_attributes(%{managed_nest_id: nest.id, tag_id: tag.id})
        |> Ash.create!()
      end

      %{nest: nest, kept: nest_state(nest)}
    end

    test "draws a row's own managed rows, and a plain save keeps them", ctx do
      %{conn: conn, editor: editor, nest: nest, kept: kept} = ctx

      conn
      |> log_in(editor)
      |> visit("/test/managed_nest/#{nest.id}/update")
      |> assert_has(~s(#{@modal} [name="form[rows][0][status]"][value="a"]))
      |> assert_has(~s(#{@modal} [name="form[rows][0][parts][0][label]"][value="p1"]))
      |> assert_has(~s(#{@modal} [name="form[rows][0][parts][1][label]"][value="p2"]))
      |> click_button("#{@modal} button", "Save")
      |> refute_has("#flash-error")

      assert nest_state(nest) == kept
    end

    # A part's update manages its row back up the chain: the walk stops where
    # it came round, so the form opens and saves.
    test "a managed relationship pointing back up opens and saves", ctx do
      %{conn: conn, editor: editor, nest: nest, kept: kept} = ctx

      loads = AshQuick.LiveView.Utils.managed_loads(ManagedNest, :update)
      parts = loads |> Keyword.fetch!(:rows) |> Keyword.fetch!(:parts)
      refute parts |> Keyword.fetch!(:row) |> Keyword.has_key?(:parts)

      conn
      |> log_in(editor)
      |> visit("/test/managed_nest/#{nest.id}/update")
      |> fill_in(~s(#{@modal} [name="form[code]"]), "Code", with: "#{nest.code}-renamed")
      |> click_button("#{@modal} button", "Save")
      |> refute_has("#flash-error")

      assert nest_state(nest) == kept
    end

    test "a plain save keeps every many_to_many join and its join attribute", ctx do
      %{conn: conn, editor: editor, nest: nest, kept: kept} = ctx

      conn
      |> log_in(editor)
      |> visit("/test/managed_nest/#{nest.id}/update")
      |> assert_has(~s(#{@modal} [name="form[tags][0][name]"][value="heavy"]))
      |> assert_has(~s(#{@modal} [name="form[tags][1][name]"][value="light"]))
      |> click_button("#{@modal} button", "Save")
      |> refute_has("#flash-error")

      assert nest_state(nest) == kept
      assert %{tags: [{"heavy", 5}, {"light", 1}]} = kept
    end
  end

  defp nest_state(nest) do
    rows =
      Row
      |> Ash.Query.filter(managed_nest_id == ^nest.id)
      |> Ash.Query.load(:parts)
      |> Ash.read!()
      |> Enum.map(&{&1.id, &1.status, Enum.map(&1.parts, fn part -> {part.id, part.label} end)})

    tags =
      Tagging
      |> Ash.Query.filter(managed_nest_id == ^nest.id)
      |> Ash.Query.load(:tag)
      |> Ash.read!()
      |> Enum.map(&{&1.tag.name, &1.weight})
      |> Enum.sort()

    %{rows: rows, tags: tags}
  end

  defp items_of(record) do
    Item
    |> Ash.Query.filter(managed_rows_id == ^record.id)
    |> Ash.Query.sort(status: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&Map.take(&1, [:id, :status, :note, :secret]))
  end
end
