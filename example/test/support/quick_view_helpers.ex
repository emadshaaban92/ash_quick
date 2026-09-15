defmodule ExampleWeb.QuickViewHelpers do
  @moduledoc """
  The parts of a QuickView that `PhoenixTest` cannot reach on its own.

  Three of them, each for the same reason: the markup is AshQuick's rather than
  the application's, so a test driving it has to know a shape it did not write.

    * **Row actions** resolve when their menu is opened, not when the row
      renders — authorizing every row's actions up front is what makes a large
      `?limit=` slow. Until `open_row_actions/2` runs, a row offers a
      placeholder, and both `assert_has` and `refute_has` over its actions mean
      nothing.
    * **A forged row action** is the only way to test the policy rather than the
      UI. A missing link stops nobody from pushing the event behind it.
    * **A relationship dropdown** is a `LiveSelect` component with its own
      `phx-target`. Its options are loaded by the component, so they are not in
      the initial render and a plain `assert_has` over them fails whether or not
      the read is right.

  Every function is session-first and chainable except `dropdown_entries/3`,
  which returns the entries.
  """

  import ExUnit.Assertions

  alias Phoenix.LiveViewTest

  @doc """
  Opens a list row's overflow menu, so its actions are on the page.

  Clicks the real trigger rather than pushing the event by name, so the binding
  the browser relies on is part of what the assertion proves.
  """
  def open_row_actions(session, record_id) do
    PhoenixTest.unwrap(session, fn view ->
      view
      |> LiveViewTest.element(~s([id="#{record_id}-row-actions-dropdown"] [role="button"]))
      |> LiveViewTest.render_click()
    end)
  end

  @doc """
  Pushes a row action's event without clicking anything.

  What someone editing the DOM in DevTools, or hand-crafting a WebSocket frame,
  would send. Hiding the link is UI; the policy behind it is the boundary, and
  only this tests the boundary.
  """
  def force_row_action(session, record_id, action_name) do
    PhoenixTest.unwrap(session, fn view ->
      LiveViewTest.render_click(view, "row_action_click", %{
        "id" => record_id,
        "action_name" => to_string(action_name)
      })
    end)
  end

  @doc "The CSS selector for one list row, addressed by the record's id."
  def row(record_id), do: ~s(tr[id="#{record_id}"])

  @doc """
  The entry labels the dropdown labelled `label` offers once opened.

  `select_entry/3` proves one entry is pickable; this proves what the whole
  option list is. A dropdown reading through the wrong action, or dropping the
  argument it searches by, gets the *set* wrong while every individual pick
  still works — which an assertion over one entry cannot see.
  """
  def dropdown_entries(%PhoenixTest.Live{view: view}, label) do
    field = find_live_select!(view, label)

    view
    |> open_dropdown(field)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  @doc "Picks `entry` from the dropdown labelled `label`."
  def select_entry(session, label, entry) do
    PhoenixTest.unwrap(session, fn view ->
      field = find_live_select!(view, label)

      view
      |> open_dropdown(field)
      |> Enum.find(&(&1 |> LazyHTML.text() |> String.contains?(entry)))
      |> case do
        nil ->
          flunk("no entry matching #{inspect(entry)} in the #{inspect(label)} dropdown")

        element ->
          idx = element |> LazyHTML.attribute("data-idx") |> List.first()

          view
          |> LiveViewTest.element(field.selector)
          |> LiveViewTest.render_hook("option_click", %{idx: idx})
      end
    end)
  end

  # Clicking the text input is what `phx-focus` hangs off, so the options are
  # the component's own unsearched read rather than whatever the initial render
  # happened to embed.
  defp open_dropdown(view, field) do
    view
    |> LiveViewTest.element(field.text_input_selector)
    |> LiveViewTest.render_click()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(field.dropdown_entries_selector)
    |> Enum.to_list()
  end

  defp find_live_select!(view, label) do
    html = LiveViewTest.render(view)

    label_selector =
      html
      |> PhoenixTest.Query.find_by_label!("label", label)
      |> PhoenixTest.Element.build_selector()

    case PhoenixTest.Query.find(html, "#{label_selector} ~ div[phx-hook='LiveSelect']") do
      {:found, element} ->
        selector = PhoenixTest.Element.build_selector(element)

        %{
          selector: selector,
          dropdown_entries_selector: "#{selector} > ul > li > div",
          text_input_selector: "#{selector} > div > input[type='text']"
        }

      :not_found ->
        raise ArgumentError, "no dropdown labelled #{inspect(label)} on the page"

      {:found_many, _elements} ->
        raise ArgumentError, "more than one dropdown labelled #{inspect(label)}"
    end
  end
end
