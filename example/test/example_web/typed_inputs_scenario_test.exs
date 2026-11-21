defmodule ExampleWeb.TypedInputsScenarioTest do
  @moduledoc """
  What a form draws for each field its typed inputs cover, and what it reads
  back.

  A number is a text input with `inputmode` for a phone's number pad, unless
  its constraints allow a negative value, and reads left to right. Digits an
  Arabic or Persian keyboard types are saved as the number they mean. A date,
  a time to the second and a naive datetime get the browser's pickers, and a
  string its length limits where the browser counts no stricter than Ash.

  `Example.Test.TypedInputs` holds the fields. Only this test writes to its
  table.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.TypedInputs

  @modal "#ash-quick-action-modal"

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  describe "the create form" do
    test "draws each field as its type", %{conn: conn} do
      conn
      |> visit(~p"/test/typed_inputs/create")
      # Numbers stay text: the pad comes from inputmode.
      |> assert_has("input[name='form[quantity]'][type='text'][dir='ltr']")
      |> refute_has("input[name='form[quantity]'][inputmode]")
      |> assert_has("input[name='form[stock]'][type='text'][inputmode='numeric'][dir='ltr']")
      # Typed left to right, but lined up with the other inputs on a
      # right-to-left page.
      |> assert_has("input[name='form[quantity]'].rtl\\:text-right")
      |> refute_has("input[name='form[code]'].rtl\\:text-right")
      |> assert_has("input[name='form[boxes]'][type='text'][inputmode='numeric']")
      |> assert_has("input[name='form[weight]'][type='text'][inputmode='decimal']")
      |> assert_has("input[name='form[ratio]'][type='text'][inputmode='decimal']")
      |> assert_has("input[name='form[balance]'][type='text'][dir='ltr']")
      |> refute_has("input[name='form[balance]'][inputmode]")
      |> assert_has("input[name='form[due_on]'][type='date']")
      |> assert_has("input[name='form[opens_at]'][type='time'][step='1']")
      # A time input carries milliseconds at most.
      |> assert_has("input[name='form[precise_at]'][type='text']")
      |> assert_has("input[name='form[logged_at]'][type='datetime-local'][step='1']")
      |> assert_has("input[name='form[short_name]'][minlength='2']")
      # A browser would cut a pasted value short at a count Ash, trimming
      # first, does not make: no string gets a maxlength.
      |> refute_has("input[maxlength]")
      # Counted in bytes, a browser's count may be under Ash's: no minlength.
      |> refute_has("input[name='form[byte_name]'][minlength]")
      |> assert_has("input[name='form[glyph_name]'][minlength='1']")
      |> refute_has("input[name='form[code]'][dir]")
    end

    test "saves Arabic-Indic and Persian digits as the numbers they mean", %{conn: conn} do
      code = unique("T")

      conn
      |> visit(~p"/test/typed_inputs/create")
      |> fill_in("Code", with: code)
      |> fill_in("Quantity", with: "-١٢٬٣٤٥")
      |> fill_in("Stock", with: "۴۲")
      |> fill_in("Boxes", with: "٧")
      |> fill_in("Weight", with: "١٢٫٥")
      |> fill_in("Ratio", with: "٠٫٢٥")
      |> fill_in("Due On", with: "2026-11-20")
      |> fill_in("Opens At", with: "08:15:30")
      |> fill_in("Logged At", with: "2026-03-04T05:06:07")
      |> click_button("Save")
      |> refute_has("#flash-error")

      saved = saved(code)
      assert saved.quantity == -12_345
      assert saved.stock == 42
      assert saved.boxes == 7
      assert Decimal.equal?(saved.weight, Decimal.new("12.5"))
      assert saved.ratio == 0.25
      assert saved.due_on == ~D[2026-11-20]
      assert saved.opens_at == ~T[08:15:30]
      assert saved.logged_at == ~N[2026-03-04 05:06:07]
    end

    test "keeps the digits a text field was given", %{conn: conn} do
      code = "رمز-١٢٣-" <> unique("T")

      conn
      |> visit(~p"/test/typed_inputs/create")
      |> fill_in("Code", with: code)
      |> fill_in("Short Name", with: "٤٥٦")
      |> click_button("Save")
      |> refute_has("#flash-error")

      assert saved(code).short_name == "٤٥٦"
    end

    test "reads an argument that holds a number the same way", %{conn: conn} do
      code = unique("T")

      conn
      |> visit(~p"/test/typed_inputs/create?action=with_tally")
      |> assert_has("input[name='form[tally]'][type='text'][dir='ltr']")
      |> fill_in("Code", with: code)
      |> fill_in("Tally", with: "٩٩")
      |> click_button("Save")
      |> refute_has("#flash-error")

      assert saved(code).quantity == 99
    end

    test "reads a decimal comma as a point where it cannot be a thousands one", %{conn: conn} do
      code = unique("T")

      conn
      |> visit(~p"/test/typed_inputs/create")
      |> fill_in("Code", with: code)
      |> fill_in("Weight", with: " ١٢,٥ ")
      |> fill_in("Ratio", with: "٠،٢٥")
      |> click_button("Save")
      |> refute_has("#flash-error")

      saved = saved(code)
      assert Decimal.equal?(saved.weight, Decimal.new("12.5"))
      assert saved.ratio == 0.25
    end

    test "leaves a comma that may be a thousands one for Ash to refuse", %{conn: conn} do
      code = unique("T")

      conn
      |> visit(~p"/test/typed_inputs/create")
      |> fill_in("Code", with: code)
      |> fill_in("Weight", with: "1,000")
      |> click_button("Save")
      |> assert_has("#form_weight-errors", text: "is invalid")

      refute saved(code)
    end

    test "reads the numbers of an embed and of a related record", %{conn: conn} do
      code = unique("T")
      {:ok, view, _html} = live(conn, ~p"/test/typed_inputs/create?action=with_parts")

      view |> element("button[phx-value-path='form[parts]']") |> render_click()

      view
      |> form("form[phx-submit]", %{
        "form" => %{
          "code" => code,
          "dims" => %{"width" => "٤٢", "label" => "٤٢"},
          "parts" => %{"0" => %{"count" => "۷"}}
        }
      })
      |> render_submit()

      refute render(view) =~ "is invalid"

      saved = code |> saved() |> Ash.load!(:parts, authorize?: false)
      assert saved.dims.width == 42
      # A text field in the embed keeps what was typed.
      assert saved.dims.label == "٤٢"
      assert Enum.map(saved.parts, & &1.count) == [7]
    end

    # The inner embed's sub-form config is built when it is added, by the
    # outer one's `updater`, after the configs set up front were given theirs.
    test "reads the numbers of an embed inside an embed", %{conn: conn} do
      code = unique("T")
      {:ok, view, _html} = live(conn, ~p"/test/typed_inputs/create?action=with_parts")

      view
      |> form("form[phx-submit]", %{"form" => %{"code" => code}})
      |> render_submit(%{"form" => %{"dims" => %{"width" => "1", "inner" => %{"depth" => "٣"}}}})

      refute render(view) =~ "is invalid"
      assert saved(code).dims.inner.depth == 3
    end

    test "still lets Ash refuse what it cannot read", %{conn: conn} do
      conn
      |> visit(~p"/test/typed_inputs/create")
      |> fill_in("Code", with: unique("T"))
      |> fill_in("Stock", with: "١٢abc")
      |> click_button("Save")
      |> assert_has("[phx-feedback-for], .text-error", text: "is invalid")
    end
  end

  describe "the update form" do
    test "shows each held value as its input reads it", %{conn: conn} do
      record = typed_input(logged_at: ~N[2026-03-04 05:06:07], opens_at: ~T[08:15:30])

      conn
      |> visit(~p"/test/typed_inputs/#{record.id}/update")
      |> assert_has("input[name='form[due_on]'][value='2026-10-19']")
      |> assert_has("input[name='form[opens_at]'][value='08:15:30']")
      # The seconds stay, so an untouched field posts back what it holds.
      |> assert_has("input[name='form[logged_at]'][value='2026-03-04T05:06:07']")
      |> assert_has("input[name='form[stock]'][value='5']")
      |> click_button("Save")
      |> refute_has("#flash-error")

      saved = Ash.reload!(record, authorize?: false)
      assert saved.logged_at == ~N[2026-03-04 05:06:07]
      assert saved.opens_at == ~T[08:15:30]
    end
  end

  describe "an update form's embed" do
    test "reads its numbers too", %{conn: conn} do
      record =
        Ash.create!(TypedInputs, %{code: unique("T"), dims: %{width: 3, label: "a"}},
          action: :with_parts,
          authorize?: false
        )

      {:ok, view, _html} = live(conn, ~p"/test/typed_inputs/#{record.id}/resize")

      view
      |> form("form[phx-submit]", %{"form" => %{"dims" => %{"width" => "٨"}}})
      |> render_submit()

      refute render(view) =~ "is invalid"
      assert Ash.reload!(record, authorize?: false).dims.width == 8
    end
  end

  describe "the bulk form" do
    test "reads Arabic-Indic digits too", %{conn: conn} do
      first = typed_input([])
      second = typed_input([])

      conn
      |> visit(~p"/test/typed_inputs")
      |> tick_rows([first.id, second.id])
      |> click_link("a[phx-click*='bulk_action']", "Restock")
      |> assert_has("#{@modal} input[name='form[stock]'][inputmode='numeric']")
      |> fill_in("#{@modal} input", "Stock", with: "٣٠")
      |> click_button("#{@modal} button", "Save")
      |> refute_has(@modal)
      |> refute_has("#flash-error")

      assert Ash.reload!(first, authorize?: false).stock == 30
      assert Ash.reload!(second, authorize?: false).stock == 30
    end
  end

  defp saved(code) do
    TypedInputs |> Ash.read!(authorize?: false) |> Enum.find(&(&1.code == code))
  end

  defp typed_input(attrs) do
    Ash.create!(
      TypedInputs,
      Map.merge(%{code: unique("T"), stock: 5, due_on: ~D[2026-10-19]}, Map.new(attrs)),
      authorize?: false
    )
  end
end
