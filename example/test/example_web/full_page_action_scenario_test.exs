defmodule ExampleWeb.FullPageActionScenarioTest do
  @moduledoc """
  An action the resource declares `full_page` opens as a page of its own,
  from every place an action is opened: the list's New button, a row's
  actions, and a details page's buttons. Nothing is drawn under it.

  It returns where the modal would have. Cancel and a successful update or
  destroy lead back to the page it was opened from, at its search; reached
  with nothing before it, to the record's page (the list for a create). A
  create goes on to the record it made, and a destroy of the record a page
  was about goes to the list.

  `Example.Test.LongForms` declares `:create`, `:rework` and `:destroy`;
  its `:update` stays in the modal.
  """
  use ExampleWeb.ConnCase, async: true

  require Ash.Query

  alias Example.Test.LongForms

  @modal "#ash-quick-action-modal"
  @form "form[phx-submit=save]"

  setup %{conn: conn, admin: admin} do
    record = Ash.create!(LongForms, %{code: unique("LF-"), note: "first"}, authorize?: false)
    %{conn: log_in(conn, admin), record: record}
  end

  defp assert_full_page(view) do
    assert has_element?(view, @form)
    refute has_element?(view, @modal)
    refute has_element?(view, "[inert]")
  end

  defp reload(record), do: Ash.get!(LongForms, record.id, authorize?: false)

  # Each list cell's text, matched whole: a `unique/1` code can be the start
  # of another test's in the shared table.
  defp cells(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("td")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  describe "a create" do
    test "opens from the list as a page, and cancelling returns to the list", ctx do
      %{conn: conn, record: record} = ctx
      search = record.code

      {:ok, view, _html} = live(conn, ~p"/test/long_forms?search=#{search}")

      view |> element("button", "Create") |> render_click()
      assert_patch(view, ~p"/test/long_forms/create?search=#{search}")
      assert_full_page(view)
      refute record.code in cells(view)

      view |> element("#{@form} button", "Cancel") |> render_click()

      assert_patch(view, ~p"/test/long_forms?search=#{search}")
      assert record.code in cells(view)
    end

    test "goes on to the record it made", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/test/long_forms")

      view |> element("button", "Create") |> render_click()
      assert_full_page(view)

      code = unique("LF-")
      view |> form(@form, %{"form" => %{"code" => code}}) |> render_submit()

      created = LongForms |> Ash.Query.filter(code == ^code) |> Ash.read_one!(authorize?: false)
      assert_patch(view, ~p"/test/long_forms/#{created.id}")
      assert render(view) =~ "Record saved successfully"
    end

    test "reached by a link returns to the list", %{conn: conn, record: record} do
      {:ok, view, _html} = live(conn, ~p"/test/long_forms/create")
      assert_full_page(view)

      view |> element("#{@form} button", "Cancel") |> render_click()

      assert_patch(view, ~p"/test/long_forms")
      assert record.code in cells(view)
    end
  end

  describe "an update" do
    test "opened from a row returns to the searched list", ctx do
      %{conn: conn, record: record} = ctx
      search = record.code

      {:ok, view, _html} = live(conn, ~p"/test/long_forms?search=#{search}")

      view |> element("##{record.id}-row-actions-dropdown [role=button]") |> render_click()
      view |> element("##{record.id}-action-rework") |> render_click()

      assert_patch(view, ~p"/test/long_forms/#{record.id}/rework?search=#{search}")
      assert_full_page(view)

      # Nothing underneath says which record this is, so the form does.
      assert has_element?(view, "h2 + p", record.code)

      note = unique("reworked ")
      view |> form(@form, %{"form" => %{"note" => note}}) |> render_submit()

      assert_patch(view, ~p"/test/long_forms?search=#{search}")
      assert render(view) =~ "Record saved successfully"
      assert note in cells(view)
      assert reload(record).note == note
    end

    test "opened from the record returns to the record", %{conn: conn, record: record} do
      {:ok, view, _html} = live(conn, ~p"/test/long_forms/#{record.id}")

      view |> element("button", "Rework") |> render_click()
      assert_patch(view, ~p"/test/long_forms/#{record.id}/rework")
      assert_full_page(view)

      view |> form(@form, %{"form" => %{"note" => "reworked"}}) |> render_submit()

      assert_patch(view, ~p"/test/long_forms/#{record.id}")
      assert has_element?(view, ~s([data-field="note"] dd), "reworked")
    end

    test "reached by a link cancels to the record, leaving it as it was", ctx do
      %{conn: conn, record: record} = ctx

      {:ok, view, _html} = live(conn, ~p"/test/long_forms/#{record.id}/rework")
      assert_full_page(view)

      view |> form(@form, %{"form" => %{"note" => "never saved"}}) |> render_change()
      view |> element("#{@form} button", "Cancel") |> render_click()

      assert_patch(view, ~p"/test/long_forms/#{record.id}")
      assert has_element?(view, ~s([data-field="note"] dd), "first")
      assert reload(record).note == "first"
    end

    test "not declared full_page still opens in the modal", %{conn: conn, record: record} do
      {:ok, view, _html} = live(conn, ~p"/test/long_forms/#{record.id}")

      view |> element("button", "Update") |> render_click()
      assert_patch(view, ~p"/test/long_forms/#{record.id}/update")

      assert has_element?(view, "#{@modal} #{@form}")
      assert has_element?(view, "[inert]", record.code)

      # The record's page underneath names it, so the modal's form does not.
      refute has_element?(view, "#{@modal} h2 + p")
    end
  end

  describe "a destroy" do
    # Its own prefix, so the search lists these two rows and no other test's.
    # The trailing "-" keeps one prefix from being the start of another.
    test "opened from a row returns to the searched list", %{conn: conn} do
      search = unique("LFD-") <> "-"
      record = Ash.create!(LongForms, %{code: search <> "1"}, authorize?: false)
      other = Ash.create!(LongForms, %{code: search <> "2"}, authorize?: false)

      {:ok, view, _html} = live(conn, ~p"/test/long_forms?search=#{search}")

      view |> element("##{record.id}-row-actions-dropdown [role=button]") |> render_click()
      view |> element("##{record.id}-action-destroy") |> render_click()

      assert_patch(view, ~p"/test/long_forms/#{record.id}/destroy?search=#{search}")
      assert_full_page(view)
      assert has_element?(view, "p", "Are you sure?")

      view |> form(@form) |> render_submit()

      assert_patch(view, ~p"/test/long_forms?search=#{search}")
      assert render(view) =~ "Record deleted successfully"
      refute record.code in cells(view)
      assert other.code in cells(view)
    end

    test "opened from the record it destroys goes to the list", %{conn: conn, record: record} do
      {:ok, view, _html} = live(conn, ~p"/test/long_forms/#{record.id}")

      view |> element("button", "Delete") |> render_click()
      assert_patch(view, ~p"/test/long_forms/#{record.id}/destroy")
      assert_full_page(view)

      view |> form(@form) |> render_submit()

      assert_patch(view, ~p"/test/long_forms")
      refute record.code in cells(view)
    end

    test "reached by a link goes to the list, not to the record it destroyed", ctx do
      %{conn: conn, record: record} = ctx

      {:ok, view, _html} = live(conn, ~p"/test/long_forms/#{record.id}/destroy")
      assert_full_page(view)

      view |> form(@form) |> render_submit()

      assert_patch(view, ~p"/test/long_forms")
      assert render(view) =~ "Record deleted successfully"
    end

    test "reached by a link cancels to the record", %{conn: conn, record: record} do
      {:ok, view, _html} = live(conn, ~p"/test/long_forms/#{record.id}/destroy")

      view |> element("#{@form} button", "Cancel") |> render_click()

      assert_patch(view, ~p"/test/long_forms/#{record.id}")
      assert has_element?(view, ~s([data-field="code"] dd), record.code)
    end
  end
end
