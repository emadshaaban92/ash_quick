defmodule ExampleWeb.HiddenFieldsScenarioTest do
  @moduledoc """
  An update form leaves out a field a field policy hides from its reader on
  the record it updates, and the save leaves that field as it was.

  Ash reads such a field back as `%Ash.ForbiddenField{}`, which an input cannot
  draw and a sub-form cannot be built over: the form used to crash, and an
  input drawn empty would have saved its emptiness over a value its reader
  never saw. `Example.Test.HiddenFields` hides a number, a single attachment,
  a list of them, an embed and a `belongs_to` from all but an admin, and
  `:memo` on closed records; its `:edit` accepts them all.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.HiddenFields

  @modal "#ash-quick-action-modal"
  @bulk "a[phx-click*='bulk_action']"
  # Each hidden field by the inputs it draws, whatever their shape: a number,
  # an upload, a drop zone, an embed's sub-form and a dropdown.
  @hidden_inputs Enum.map(~w(salary photo documents address owner_id), &~s([name^="form[#{&1}]"]))

  describe "an update form" do
    test "leaves out every field hidden on every record, and keeps each on save", ctx do
      %{conn: conn, editor: editor} = ctx
      record = hidden_record(memo: "seen")

      session =
        conn
        |> log_in(editor)
        |> visit("/test/hidden_fields/#{record.id}/edit")
        |> assert_has("#{@modal} label", text: "Memo")

      session =
        Enum.reduce(@hidden_inputs, session, &refute_has(&2, "#{@modal} #{&1}"))

      session
      |> fill_in("Code", with: "#{record.code}-renamed")
      |> click_button("Save")
      |> refute_has("#flash-error")

      stored = Ash.get!(HiddenFields, record.id, authorize?: false)
      assert stored.code == "#{record.code}-renamed"
      assert_kept(stored, record)
    end

    test "leaves out a field hidden on some records from those records' forms", ctx do
      %{conn: conn, editor: editor} = ctx
      closed = hidden_record(memo: "kept", open: false)

      conn
      |> log_in(editor)
      |> visit("/test/hidden_fields/#{closed.id}/edit")
      |> refute_has("#{@modal} label", text: "Memo")
      |> fill_in("Code", with: "#{closed.code}-renamed")
      |> click_button("Save")
      |> refute_has("#flash-error")

      assert Ash.get!(HiddenFields, closed.id, authorize?: false).memo == "kept"
    end

    test "gives a reader who may see the fields their inputs", %{conn: conn, admin: admin} do
      record = hidden_record(memo: "kept", open: false)

      session =
        conn
        |> log_in(admin)
        |> visit("/test/hidden_fields/#{record.id}/edit")
        |> assert_has("#{@modal} label", text: "Memo")

      session =
        Enum.reduce(@hidden_inputs, session, &assert_has(&2, "#{@modal} #{&1}"))

      session
      |> fill_in("Salary", with: "4300")
      |> click_button("Save")
      |> refute_has("#flash-error")

      assert Ash.get!(HiddenFields, record.id, authorize?: false).salary == 4300
    end

    test "is refused when its reader may change none of what it takes", ctx do
      %{conn: conn, editor: editor, admin: admin} = ctx
      record = hidden_record([])

      conn
      |> log_in(editor)
      |> visit("/test/hidden_fields/#{record.id}/set_salary")
      |> assert_has(@modal, text: "Access Forbidden")
      |> refute_has("#{@modal} button", text: "Confirm")

      build_conn()
      |> log_in(admin)
      |> visit("/test/hidden_fields/#{record.id}/set_salary")
      |> assert_has("#{@modal} label", text: "Salary")
    end

    # The panel draws no form, and a missing form stops nobody from pushing the
    # save behind it.
    test "refuses a save pushed at the panel", %{conn: conn, editor: editor} do
      record = hidden_record([])

      conn
      |> log_in(editor)
      |> visit("/test/hidden_fields/#{record.id}/set_salary")
      |> assert_has(@modal, text: "Access Forbidden")
      |> forge("save", %{"salary" => "1"})
      |> assert_has("#flash-error", text: "You don't have permission to do that.")

      assert Ash.get!(HiddenFields, record.id, authorize?: false).salary == record.salary
    end

    # Once `manage_relationship` has written the lines, the update loads them
    # back through the hidden `:address`, which Ash steps over from 3.37.3.
    test "saves a related record on a record whose embed is hidden", ctx do
      %{conn: conn, editor: editor} = ctx
      record = hidden_record([])

      conn
      |> log_in(editor)
      |> visit("/test/hidden_fields/#{record.id}/edit_lines")
      |> click_button("Add")
      |> fill_in("Label", with: "added")
      |> click_button("#{@modal} button", "Save")
      |> refute_has("#flash-error")

      assert [%{label: "added"}] = lines_of(record)
    end

    test "leaves out an argument named like a hidden field", ctx do
      %{conn: conn, editor: editor} = ctx
      record = hidden_record(memo: "kept")

      conn
      |> log_in(editor)
      |> visit("/test/hidden_fields/#{record.id}/probe_arg")
      |> assert_has("#{@modal} label", text: "Code")
      |> refute_has(~s(#{@modal} [name^="form[salary]"]))
      |> fill_in("Code", with: "#{record.code}-renamed")
      |> click_button("Save")
      |> refute_has("#flash-error")

      stored = Ash.get!(HiddenFields, record.id, authorize?: false)
      assert stored.code == "#{record.code}-renamed"
    end

    # The emptied list's `[]` is put back only for an argument the form draws.
    test "sends no list argument named like a hidden field", ctx do
      %{conn: conn, editor: editor} = ctx
      record = hidden_record(tags: [:a, :b])

      conn
      |> log_in(editor)
      |> visit("/test/hidden_fields/#{record.id}/probe_tags")
      |> refute_has(~s(#{@modal} [name^="form[tags]"]))
      |> fill_in("Code", with: "#{record.code}-renamed")
      |> click_button("Save")
      |> refute_has("#flash-error")

      stored = Ash.get!(HiddenFields, record.id, authorize?: false)
      assert stored.code == "#{record.code}-renamed"
      assert stored.tags == [:a, :b]
    end

    test "leaves out a field hidden on a related record in its sub-form", ctx do
      %{conn: conn, editor: editor, admin: admin} = ctx
      keeper = hidden_keeper(phone: "555-0100")

      record =
        hidden_record(address: nil)
        |> Ash.Changeset.for_update(:edit, %{})
        |> Ash.Changeset.force_change_attribute(:keeper_id, keeper.id)
        |> Ash.update!(authorize?: false)

      conn
      |> log_in(editor)
      |> visit("/test/hidden_fields/#{record.id}/edit_keeper")
      |> assert_has(~s(#{@modal} [name="form[keeper][name]"]))
      |> refute_has(~s(#{@modal} [name="form[keeper][phone]"]))
      |> fill_in("Name", with: "Renamed")
      |> click_button("Save")
      |> refute_has("#flash-error")

      stored = Ash.get!(HiddenFields.Keeper, keeper.id, authorize?: false)
      assert stored.name == "Renamed"
      assert stored.phone == "555-0100"

      build_conn()
      |> log_in(admin)
      |> visit("/test/hidden_fields/#{record.id}/edit_keeper")
      |> assert_has(~s(#{@modal} [name="form[keeper][phone]"]))
    end
  end

  describe "a bulk update form" do
    test "leaves out a field hidden on any record, and keeps it on every row", ctx do
      %{conn: conn, editor: editor} = ctx
      rows = [hidden_record(memo: "first"), hidden_record(memo: "second", open: false)]

      session =
        conn
        |> log_in(editor)
        |> visit("/test/hidden_fields")
        |> tick_rows(Enum.map(rows, & &1.id))
        |> click_link(@bulk, "Retag")
        |> assert_has("#{@modal} label", text: "Code")

      session =
        Enum.reduce(~w(salary memo address owner_id), session, fn field, session ->
          refute_has(session, ~s(#{@modal} [name^="form[#{field}]"]))
        end)

      session
      |> fill_in("Code", with: unique("BULK-"))
      |> click_button("#{@modal} button", "Save")
      |> refute_has("#flash-error")

      for row <- rows do
        stored = Ash.get!(HiddenFields, row.id, authorize?: false)
        assert stored.salary == row.salary
        assert stored.address.street == row.address.street
        assert stored.owner_id == row.owner_id
        assert stored.memo == row.memo
      end
    end

    test "is closed by a refused open, so a later save runs nothing", ctx do
      %{conn: conn, editor: editor} = ctx
      row = hidden_record(memo: "first")

      conn
      |> log_in(editor)
      |> visit("/test/hidden_fields")
      |> tick_rows([row.id])
      |> click_link(@bulk, "Retag")
      |> unwrap(&render_click(&1, "bulk_action", %{"action_name" => "set_salary"}))
      |> refute_has(@modal)
      |> unwrap(&render_submit(&1, "bulk_save", %{"form" => %{"code" => unique("BULK-")}}))
      |> assert_has("#flash-error", text: "You don't have permission to do that.")

      assert Ash.get!(HiddenFields, row.id, authorize?: false).code == row.code
    end

    test "leaves out an argument named like a field hidden on any record", ctx do
      %{conn: conn, editor: editor, admin: admin} = ctx
      row = hidden_record(memo: "first")

      conn
      |> log_in(editor)
      |> visit("/test/hidden_fields")
      |> tick_rows([row.id])
      |> click_link(@bulk, "Probe Arg")
      |> assert_has("#{@modal} label", text: "Code")
      |> refute_has(~s(#{@modal} [name^="form[salary]"]))

      build_conn()
      |> log_in(admin)
      |> visit("/test/hidden_fields")
      |> tick_rows([row.id])
      |> click_link(@bulk, "Probe Arg")
      |> assert_has(~s(#{@modal} [name^="form[salary]"]))
    end

    test "offers an admin every field", %{conn: conn, admin: admin} do
      row = hidden_record(memo: "first")

      session =
        conn
        |> log_in(admin)
        |> visit("/test/hidden_fields")
        |> tick_rows([row.id])
        |> click_link(@bulk, "Retag")

      Enum.reduce(["Memo", "Salary", "Owner"], session, fn label, session ->
        assert_has(session, "#{@modal} label", text: label)
      end)
    end
  end

  # Pushes a form event with `params` as its `form`, drawn or not.
  defp forge(session, event, params) do
    unwrap(session, &render_submit(&1, event, %{"form" => params}))
  end

  defp assert_kept(stored, record) do
    assert stored.salary == record.salary
    assert stored.photo.key == record.photo.key
    assert Enum.map(stored.documents, & &1.key) == Enum.map(record.documents, & &1.key)
    assert stored.address.street == record.address.street
    assert stored.owner_id == record.owner_id
  end

  defp hidden_keeper(attrs) do
    HiddenFields.Keeper
    |> Ash.Changeset.for_create(:create, Map.merge(%{name: "Keeper"}, Map.new(attrs)))
    |> Ash.create!(authorize?: false)
  end

  defp lines_of(record) do
    HiddenFields.Line
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.hidden_fields_id == record.id))
  end

  defp hidden_record(attrs) do
    owner =
      HiddenFields.Owner
      |> Ash.Changeset.for_create(:create, %{name: unique("Owner ")})
      |> Ash.create!(authorize?: false)

    HiddenFields
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          code: unique("HF-"),
          salary: 4200,
          photo: attachment("private/hidden/#{unique("photo")}.jpg"),
          documents: [attachment("private/hidden/#{unique("doc")}.pdf", :document)],
          address: %{street: "1 Hidden Way"},
          owner_id: owner.id
        },
        Map.new(attrs)
      )
    )
    |> Ash.create!(authorize?: false)
  end

  defp attachment(key, file_type \\ :image) do
    %{key: key, file_type: file_type, original_filename: Path.basename(key)}
  end
end
