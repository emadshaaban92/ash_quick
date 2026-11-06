defmodule ExampleWeb.FilterPicker do
  @moduledoc """
  Drives the `LiveSelect` a filter row picks Any Of and Has Any Of values
  with, the way its hook does in a browser.

  Pushing the form's change event by hand proves only that the form reads
  what the test sent. These go through LiveSelect itself: its own events open
  the dropdown, search it, pick a value and remove a tag, and what LiveSelect
  then pushes to the page is followed as its hook follows it. A search, and
  the focus event LiveSelect is told to send, reach the form at the component
  its `data-phx-target` names, and a pick is posted only when LiveSelect asks
  for it, from the hidden inputs it rendered. What the form reads is then
  what the page would post.

  Each takes the LiveView and the row's uuid. `pick_values/3` and
  `remove_value/3` return the view; the others return labels.
  """

  import ExUnit.Assertions
  import Phoenix.LiveViewTest

  @doc "The id of the row's LiveSelect, or `nil` when the row draws none."
  def picker_id(view, uuid) do
    view
    |> query("[phx-hook=LiveSelect][id^='filter-values-#{uuid}-']")
    |> LazyHTML.attribute("id")
    |> List.first()
  end

  @doc "The labels of the row's tags, in order."
  def picked(view, uuid), do: texts(view, "##{picker!(view, uuid)} .badge")

  @doc """
  Focuses the row's input, as clicking into it does, and returns the labels
  its dropdown offers.
  """
  def focus_values(view, uuid) do
    id = picker!(view, uuid)
    view |> element("##{id}") |> render_hook("focus", %{})
    follow(view, id)
    offered(view, uuid)
  end

  @doc "Types `text` into the row's input, and returns the labels offered."
  def search_values(view, uuid, text) do
    id = picker!(view, uuid)
    view |> element("##{id}") |> render_hook("change", %{"text" => text})
    push_to_form(view, id, "live_select_change", %{"id" => id, "text" => text})
    offered(view, uuid)
  end

  @doc "The labels the row's open dropdown offers."
  def offered(view, uuid), do: texts(view, "##{picker!(view, uuid)} ul li")

  @doc """
  Picks each of `labels` from the row's dropdown, by clicking its option, and
  posts each pick.
  """
  def pick_values(view, uuid, labels) do
    for label <- labels do
      focus_values(view, uuid)
      id = picker!(view, uuid)

      options = view |> query("##{id} ul li div[data-idx]") |> Enum.to_list()
      option = Enum.find(options, &(&1 |> LazyHTML.text() |> String.trim() == label))
      assert option, "#{inspect(label)} is not offered: #{inspect(offered(view, uuid))}"
      [idx] = LazyHTML.attribute(option, "data-idx")

      view |> element("##{id}") |> render_hook("option_click", %{"idx" => idx})
      follow(view, id)
    end

    view
  end

  @doc "Removes the tag labelled `label` by its ✕, and posts what is left."
  def remove_value(view, uuid, label) do
    id = picker!(view, uuid)
    idx = Enum.find_index(picked(view, uuid), &(&1 == label))
    assert idx, "no tag #{inspect(label)}: #{inspect(picked(view, uuid))}"

    view |> element("##{id}") |> render_hook("option_remove", %{"idx" => to_string(idx)})
    follow(view, id)
    view
  end

  # What the hook does with the `select` event LiveSelect pushes: posts the
  # form when asked to, and sends the form the event it names, the
  # `phx-focus` it was given.
  defp follow(view, id) do
    assert_push_event(view, "select", %{id: ^id} = select)
    if select[:input_event], do: post(view, id)
    if event = select[:parent_event], do: push_to_form(view, id, event, %{"id" => id})
  end

  # The hook fires `input` on LiveSelect's first hidden input, which is its
  # empty-selection marker once nothing is picked, so the form's change
  # carries every input the form now holds and that one as its target.
  defp post(view, id) do
    [name | _] = view |> query("##{id} input[type=hidden]") |> LazyHTML.attribute("name")
    [_, row, input] = Regex.run(~r/^([^\[]+)\[([^\]]+)\]/, name)

    view
    |> element("#custom-filter-form")
    |> render_change(%{"_target" => [row, input]})
  end

  # LiveSelect sends its search and focus events to the component its
  # `data-phx-target` names, rather than to the form it sits in.
  defp push_to_form(view, id, event, payload) do
    [cid] = view |> query("##{id}") |> LazyHTML.attribute("data-phx-target")

    view
    |> with_target("[data-phx-component='#{cid}']")
    |> render_hook(event, payload)
  end

  defp picker!(view, uuid) do
    picker_id(view, uuid) || flunk("row #{uuid} draws no LiveSelect")
  end

  defp query(view, selector),
    do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp texts(view, selector),
    do: view |> query(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
end
