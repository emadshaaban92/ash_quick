defmodule ExampleWeb.EnumScenarioTest do
  @moduledoc """
  A field with a fixed set of values, an `Ash.Type.Enum` or an atom with
  `one_of`, is picked from a select, filtered on from the list's filter, and
  shown under its labels. An enum's labels are its own, which here are not
  the values humanized (`:live` is "On air"). An atom without `one_of` holds
  no fixed set, and is typed in.

  `Example.Test.EnumPicks` holds the fields, one of each kind.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.EnumPicks

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  describe "the form" do
    test "offers the enum's labels, and a search matches what they say", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/enum_picks/create")

      assert offered(view, "stage") == ["Being written", "On air", "Archived"]
      assert offered(view, "stage", "AIR") == ["On air"]
      assert offered(view, "stage", "live") == []

      assert offered(view, "channels") == ["E-mail", "Text message"]
      assert offered(view, "channels", "text") == ["Text message"]

      assert offered(view, "phase") == ["Open", "Closed now"]
      assert offered(view, "size") == ["Small", "Extra Large"]
    end

    test "types in an atom, or a list of them, that holds no fixed set", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/enum_picks/create?action=jot")
      html = render(view)

      for field <- ["mood", "marks"] do
        assert html =~ ~s(id="form_#{field}")
        refute html =~ "form_#{field}_live_select_component"
      end
    end

    # A known gap, kept on record rather than only routed around: a list of
    # atoms without `one_of` holds no fixed set, so it gets the plain text
    # input, which posts one string the list refuses ("is invalid"). Nothing
    # on the form can save it; `main` behaves the same. It is why the plain
    # atoms sit on `:jot` and not on the create the other tests save through.
    @tag :skip
    test "a plain list of atoms saves from the form", %{conn: conn} do
      code = unique("E")
      {:ok, view, _html} = live(conn, "/test/enum_picks/create?action=jot")

      pick(view, "stage", "On air")

      view
      |> form("form[phx-submit=save]", %{"form" => %{"code" => code, "marks" => "red"}})
      |> render_submit()

      assert [%{marks: [:red]}] = Ash.read!(EnumPicks) |> by_code(code)
    end

    test "saves the values picked from the selects", %{conn: conn} do
      code = unique("E")
      {:ok, view, _html} = live(conn, "/test/enum_picks/create")

      pick(view, "stage", "On air")
      pick(view, "channels", "Text message")
      pick(view, "channels", "E-mail")
      pick(view, "phase", "Closed now")

      view
      |> form("form[phx-submit=save]", %{"form" => %{"code" => code}})
      |> render_submit()

      assert [%{stage: :live, channels: [:sms, :email], phase: "closed_now"}] =
               Ash.read!(EnumPicks) |> by_code(code)
    end

    test "on an update, shows the stored values as picked and lists them first",
         %{conn: conn} do
      record = picks(:live, [:sms], phase: "closed_now")
      {:ok, view, _html} = live(conn, "/test/enum_picks/#{record.id}/update")

      assert picked(view, "stage") == ["live"]
      assert picked(view, "channels") == ["sms"]
      assert picked(view, "phase") == ["closed_now"]
      assert texts(view, "#form_channels_live_select_component .badge") == ["Text message"]

      assert offered(view, "stage") == ["On air", "Being written", "Archived"]
      assert offered(view, "channels") == ["Text message", "E-mail"]
      assert offered(view, "phase") == ["Closed now", "Open"]

      pick(view, "channels", "E-mail")
      view |> form("form[phx-submit=save]") |> render_submit()

      assert %{stage: :live, channels: [:sms, :email], phase: "closed_now"} =
               Ash.get!(EnumPicks, record.id)
    end
  end

  test "the list and the details page show the labels", %{conn: conn} do
    record = picks(:live, [:sms, :email], phase: "closed_now", size: :extra_large)

    conn
    |> visit(~p"/test/enum_picks")
    |> assert_has("td", text: "On air")
    |> assert_has("td", text: "Text message - E-mail")
    |> assert_has("td", text: "Closed now")
    |> assert_has("td", text: "Extra Large")
    |> visit(~p"/test/enum_picks/#{record.id}")
    |> assert_has("*", text: "On air")
    |> assert_has("*", text: "Text message - E-mail")
    |> assert_has("*", text: "Closed now")
    |> assert_has("*", text: "Extra Large")
    |> refute_has("*", text: "Live", exact: true)
    |> refute_has("*", text: "closed_now", exact: true)
  end

  describe "the list's filter" do
    test "offers each field with a fixed set by its labels, and = and !=", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/enum_picks?show_custom_filter=true")
      uuid = filter_uuid(view)

      for {field, labels} <- [
            {"stage", ["Being written", "On air", "Archived"]},
            {"phase", ["Open", "Closed now"]},
            {"size", ["Small", "Extra Large"]}
          ] do
        filter_change(view, "field_name-#{uuid}", field)

        assert texts(view, "select[name='operator-#{uuid}'] option") == ["=", "!="]
        assert texts(view, "select[name='value-#{uuid}'] option") == ["" | labels]
      end
    end

    test "types in an atom without one_of, and leaves out a list of them", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/enum_picks?show_custom_filter=true")
      uuid = filter_uuid(view)

      fields = texts(view, "select[name='field_name-#{uuid}'] option")
      assert "Mood" in fields
      refute "Marks" in fields

      filter_change(view, "field_name-#{uuid}", "mood")

      assert texts(view, "select[name='operator-#{uuid}'] option") == ["=", "!="]
      assert texts(view, "input[name='value-#{uuid}']") == [""]
    end

    test "keeps the rows equal to the picked value, or the others with !=", %{conn: conn} do
      for {field, picked, other} <- [
            {"stage", [stage: :live], [stage: :draft]},
            {"phase", [phase: "closed_now"], [phase: "open"]},
            {"size", [size: :extra_large], [size: :small]}
          ] do
        {_key, value} = hd(picked)
        matching = picks(:draft, [], picked)
        others = picks(:live, [], other)

        for {operator, kept, dropped} <- [
              {"equals", matching, others},
              {"not_equals", others, matching}
            ] do
          {:ok, view, _html} = live(conn, "/test/enum_picks?show_custom_filter=true")
          uuid = filter_uuid(view)

          filter_change(view, "field_name-#{uuid}", field)
          filter_change(view, "operator-#{uuid}", operator)
          filter_change(view, "value-#{uuid}", to_string(value))
          view |> element("#custom-filter-form") |> render_submit()

          # Whole cells: a code can be the start of another, and the shared
          # table shows other tests' rows too.
          cells = texts(view, "td")
          assert kept.code in cells, "#{field} #{operator} dropped #{kept.code}"
          refute dropped.code in cells, "#{field} #{operator} kept #{dropped.code}"
        end
      end
    end
  end

  defp picks(stage, channels, extra \\ []) do
    attrs = Map.merge(%{code: unique("E"), stage: stage, channels: channels}, Map.new(extra))
    Ash.create!(EnumPicks, attrs)
  end

  defp by_code(records, code), do: Enum.filter(records, &(&1.code == code))

  # The labels a select lists once opened, and once `search` is typed into it.
  # Focusing the text input opens LiveSelect's dropdown; the search goes to
  # the widget around it, which answers with the options to list.
  defp offered(view, field, search \\ "") do
    view |> element("#form_#{field}_text_input") |> render_focus()

    view
    |> with_target("div[phx-feedback-for='form[#{field}]']")
    |> render_hook("live_select_change", %{
      "text" => search,
      "id" => "form_#{field}_live_select_component"
    })

    texts(view, "#form_#{field}_live_select_component ul li")
  end

  # Clicks the option a select lists under `label`, the way LiveSelect's hook
  # reports a click to its component.
  defp pick(view, field, label) do
    idx = view |> offered(field) |> Enum.find_index(&(&1 == label))
    assert idx, "#{field} does not offer #{label}"

    view
    |> element("#form_#{field}_live_select_component")
    |> render_hook("option_click", %{"idx" => to_string(idx)})
  end

  # The values a select holds as picked, one hidden input each.
  defp picked(view, field) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("input[type=hidden][name='form[#{field}]'], input[name='form[#{field}][]']")
    |> LazyHTML.attribute("value")
    |> Enum.reject(&(&1 == ""))
  end

  defp filter_uuid(view) do
    [name] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("select[name^='field_name-']")
      |> LazyHTML.attribute("name")

    String.replace_prefix(name, "field_name-", "")
  end

  defp filter_change(view, name, value) do
    view
    |> element("#custom-filter-form")
    |> render_change(%{"_target" => [name], name => value})
  end

  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
