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

  alias Example.Test.KeyedRows
  alias Example.Test.ManagedNest
  alias Example.Test.ManagedRows
  alias Example.Test.ManagedRows.Row
  alias Example.Test.ManagedRows.Tag
  alias Example.Test.ManagedRows.Tagging
  alias Example.Test.ManagedRows.Item
  alias Example.Test.SeatRows

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

  # AshPhoenix matches a posted row to a stored one by its primary key when
  # the row posts it, wherever it is posted: row "1" alone, naming the second
  # record, updates that record, keeping the note the page disables and the
  # secret its sub-form does not draw; the first is removed.
  test "a row posting its key updates its own record wherever it is posted", ctx do
    %{conn: conn, editor: editor, record: record, stored: [_first, second]} = ctx
    {:ok, view, _html} = conn |> log_in(editor) |> live("/test/managed_rows/#{record.id}/update")

    render_submit(view, "save", %{
      "form" => %{"items" => %{"1" => %{"id" => second.id, "status" => "b2"}}}
    })

    assert [%{id: id, status: "b2", note: "also", secret: "second"}] = items_of(record)
    assert id == second.id
  end

  # Without its key a row is matched by its place, as AshPhoenix matches it:
  # the only row posted is the first.
  test "a row posting no key is matched by its place", ctx do
    %{conn: conn, editor: editor, record: record, stored: [first, _second]} = ctx
    {:ok, view, _html} = conn |> log_in(editor) |> live("/test/managed_rows/#{record.id}/update")

    render_submit(view, "save", %{"form" => %{"items" => %{"1" => %{"status" => "b2"}}}})

    assert [%{id: id, status: "b2", note: "keep", secret: "first"}] = items_of(record)
    assert id == first.id
  end

  # A row the page added posts itself as new. After a reconnect it is a new
  # row again, never the stored row at its place.
  test "a recovery never gives a new row a stored row's place", ctx do
    %{conn: conn, editor: editor, record: record, stored: [first, second]} = ctx
    conn = log_in(conn, editor)
    path = "/test/managed_rows/#{record.id}/update"
    form = "#{@modal} form[phx-submit=save]"
    {:ok, view, _html} = live(conn, path)

    for _row <- 1..2 do
      view
      |> element("#{form} [phx-click=remove-form][phx-value-path='form[items][0]']")
      |> render_click()
    end

    view
    |> element("#{form} [phx-click=add-form][phx-value-path='form[items]']")
    |> render_click()

    held = view |> held_params(form) |> put_in(["form", "items", "0", "status"], "c")
    assert held["form"]["items"]["0"]["_form_type"] == "create"

    {:ok, view, _html} = live(conn, path)
    render_change(view, "validate", Map.put(held, "_target", ["form", "code"]))
    view |> element(form) |> render_submit()

    assert [%{id: id, status: "c", note: nil, secret: nil}] = items_of(record)
    refute id in [first.id, second.id]
  end

  # AshPhoenix matches a row by primary key only when it posts every key
  # field: a new row drawing one field of a composite key is a new row, and
  # its recovery is taken.
  test "a recovery brings back a new row posting part of a composite key", ctx do
    record =
      KeyedRows
      |> Ash.Changeset.for_create(:create, %{
        code: unique("KEYED-"),
        members: [%{team: "alpha", note: "kept"}]
      })
      |> Ash.create!()

    conn = log_in(ctx.conn, ctx.editor)
    path = "/test/keyed_rows/#{record.id}/update"
    {:ok, view, _html} = live(conn, path)
    form = "#{@modal} form[phx-submit=save]"

    view
    |> element("#{form} [phx-click=add-form][phx-value-path='form[members]']")
    |> render_click()

    held =
      view
      |> element(form)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("input[name]:not([type=file]), select[name], textarea[name]")
      |> Enum.map(&{LazyHTML.attribute(&1, "name") |> hd(), input_value(&1)})
      |> Map.new()
      |> Map.merge(%{
        "form[code]" => "Typed",
        "form[members][1][team]" => "beta",
        "form[members][1][note]" => "new"
      })
      |> URI.encode_query()
      |> Plug.Conn.Query.decode()

    assert held["form"]["members"]["1"]["_form_type"] == "create"
    refute Map.has_key?(held["form"]["members"]["1"], "seat")

    {:ok, view, _html} = live(conn, path)
    render_change(view, "validate", held)

    assert view |> element("#{form} input[name='form[code]'][value='Typed']") |> has_element?()
    assert view |> element("#{form} [name='form[members][1][team]']") |> has_element?()

    view |> element(form) |> render_submit()

    saved = Ash.load!(Ash.get!(KeyedRows, record.id), :members)
    assert saved.code == "Typed"
    assert [%{team: "alpha", note: "kept"}, %{team: "beta", note: "new"}] = saved.members
  end

  # Rows with a primary key post it, so a recovery after the page removed a
  # stored row names the rows left by key: the one it leaves out is gone
  # again, and every other row keeps its record.
  test "a recovery after a stored row was removed keeps the page as it was", ctx do
    %{conn: conn, editor: editor, record: record, stored: [_first, second]} = ctx
    conn = log_in(conn, editor)
    path = "/test/managed_rows/#{record.id}/update"
    form = "#{@modal} form[phx-submit=save]"
    {:ok, view, _html} = live(conn, path)

    view
    |> element("#{form} [phx-click=remove-form][phx-value-path='form[items][0]']")
    |> render_click()

    view
    |> element("#{form} [phx-click=add-form][phx-value-path='form[items]']")
    |> render_click()

    held =
      view
      |> held_params(form)
      |> put_in(["form", "code"], "Typed")
      |> put_in(["form", "items", "1", "status"], "c")

    {:ok, view, _html} = live(conn, path)
    render_change(view, "validate", Map.put(held, "_target", ["form", "code"]))

    assert held_params(view, form) |> get_in(["form", "items"]) |> map_size() == 2
    assert view |> element("#{form} input[name='form[code]'][value='Typed']") |> has_element?()

    view |> element(form) |> render_submit()

    assert [
             %{id: id, status: "b", note: "also", secret: "second"},
             %{status: "c", secret: nil}
           ] = items_of(record)

    assert id == second.id
  end

  # A row keyed by its parent's id and a field of its own posts only that
  # field, the parent's id being private: part of its key. It is matched by
  # that part, so the row left after a ✕ and a reconnect is its own stored
  # row, with the secret its sub-form does not draw, and the one removed is
  # the one destroyed.
  test "a row whose key holds the parent's id keeps its record after a reconnect", ctx do
    record =
      Ash.create!(
        SeatRows,
        %{
          code: unique("SEAT-"),
          seats: [
            %{seat: "A", note: "one", secret: "sa"},
            %{seat: "B", note: "two", secret: "sb"}
          ]
        },
        authorize?: false
      )

    conn = log_in(ctx.conn, ctx.editor)
    path = "/test/seat_rows/#{record.id}/update"
    form = "#{@modal} form[phx-submit=save]"
    {:ok, view, _html} = live(conn, path)

    # The first change on a form just opened is taken as any other.
    held = view |> held_params(form) |> put_in(["form", "seats", "1", "note"], "typed")
    refute Map.has_key?(held["form"]["seats"]["1"], "seat_rows_id")
    render_change(view, "validate", Map.put(held, "_target", ["form", "seats", "1", "note"]))

    assert view
           |> element("#{form} input[name='form[seats][1][note]'][value='typed']")
           |> has_element?()

    view
    |> element("#{form} [phx-click=remove-form][phx-value-path='form[seats][0]']")
    |> render_click()

    held = held_params(view, form)

    {:ok, view, _html} = live(conn, path)
    render_change(view, "validate", Map.put(held, "_target", ["form", "code"]))

    assert view
           |> element("#{form} input[name='form[seats][0][note]'][value='typed']")
           |> has_element?()

    view |> element(form) |> render_submit()

    assert [%{seat: "B", note: "typed", secret: "sb"}] =
             SeatRows.Seat
             |> Ash.Query.filter(seat_rows_id == ^record.id)
             |> Ash.read!(authorize?: false)
  end

  defp held_params(view, form) do
    view
    |> element(form)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("input[name]:not([type=file]), select[name], textarea[name]")
    |> Enum.map(&{LazyHTML.attribute(&1, "name") |> hd(), input_value(&1)})
    |> URI.encode_query()
    |> Plug.Conn.Query.decode()
  end

  defp input_value(node) do
    case LazyHTML.attribute(node, "value") do
      [value | _] -> value
      [] -> ""
    end
  end

  defp items_of(record) do
    Item
    |> Ash.Query.filter(managed_rows_id == ^record.id)
    |> Ash.Query.sort(status: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&Map.take(&1, [:id, :status, :note, :secret]))
  end
end
