defmodule ExampleWeb.PickerDriver do
  @moduledoc """
  Drives an `AshQuick.LiveView.Picker` the way its `.Picker` hook does in a
  browser.

  Pushing the form's change event by hand proves only that the form reads
  what the test sent. These go through the picker itself: its own `search`,
  `pick`, `remove` and `clear` events, sent to the component as the hook
  sends them. When the picker replies that the selection changed, the form's
  change is posted with the picker's first hidden input as its `_target`,
  which is the input the hook fires `input` from, and with every input the
  form now holds. The picker is then told it was posted, as the hook tells
  it. What the form reads is then what the page would post.

  Each takes the LiveView and the picker's id (the component's `id`). A
  search waits for its async result. `pick/3`, `remove/3` and `clear/2`
  return the view; the others return labels.
  """

  import ExUnit.Assertions
  import Phoenix.LiveViewTest

  @doc """
  Types `text` into the picker, or opens it with nothing typed when `text` is
  `""`, and returns the labels it offers.
  """
  def search(view, id, text \\ "") do
    assert has_element?(view, "##{id}[data-aq-picker]"), "no picker #{inspect(id)} on the page"
    view |> with_target("##{id}") |> render_hook("search", %{"text" => text})
    render_async(view)
    offered(view, id)
  end

  @doc "The labels the picker's list offers, in order, an Add row among them."
  def offered(view, id), do: texts(view, "##{id}-listbox [role=option] [data-part=label]")

  @doc "The values of the options offered, in order."
  def offered_values(view, id),
    do: view |> query("##{id}-listbox [role=option]") |> LazyHTML.attribute("data-value")

  @doc """
  Picks the option labelled `label` from what the last search offered, or the
  one whose value is `value: value`, and posts the form.
  """
  def pick(view, id, label_or_value)

  def pick(view, id, value: value) do
    option = view |> query("##{id}-listbox [role=option][data-value='#{value}']") |> Enum.at(0)
    assert option, "#{inspect(value)} is not offered: #{inspect(offered_values(view, id))}"
    push(view, id, "pick", %{"value" => value, "new" => new?(option)})
  end

  def pick(view, id, label) do
    options = view |> query("##{id}-listbox [role=option]") |> Enum.to_list()
    option = Enum.find(options, &(label_of(&1) == label))
    assert option, "#{inspect(label)} is not offered: #{inspect(offered(view, id))}"
    [value] = LazyHTML.attribute(option, "data-value")
    push(view, id, "pick", %{"value" => value, "new" => new?(option)})
  end

  @doc "Removes the tag labelled `label` by its ✕, and posts the form."
  def remove(view, id, label) do
    tag =
      view
      |> query("##{id} [data-part=tag]")
      |> Enum.find(&(label_of_tag(&1) == label))

    assert tag, "no tag #{inspect(label)}: #{inspect(picked(view, id))}"
    [value] = LazyHTML.attribute(tag, "data-value")
    push(view, id, "remove", %{"value" => value})
  end

  @doc "Empties a single picker by its ✕, and posts the form."
  def clear(view, id) do
    assert has_element?(view, "##{id} [data-clear]"), "#{id} draws no clear button"
    push(view, id, "clear", %{})
  end

  @doc "The labels of what the picker holds: its tags, or its one selection."
  def picked(view, id) do
    view
    |> query("##{id} [data-part=tag], ##{id} [data-part=selection]")
    |> Enum.map(fn node ->
      label = LazyHTML.query(node, "[data-part=label], .wrap-anywhere:first-child")

      text =
        if Enum.empty?(label), do: LazyHTML.text(node), else: LazyHTML.text(Enum.at(label, 0))

      String.trim(text)
    end)
  end

  @doc "The values of the hidden inputs the picker posts, by name."
  def posted(view, id) do
    view
    |> query("##{id} input[type=hidden]")
    |> Enum.map(fn input ->
      {input |> LazyHTML.attribute("name") |> hd(),
       input |> LazyHTML.attribute("value") |> List.first()}
    end)
  end

  defp push(view, id, event, payload) do
    view |> with_target("##{id}") |> render_hook(event, payload)
    assert_reply(view, %{changed: changed} = reply)

    if changed do
      [name | _] = view |> query("##{id} input[data-picker-value]") |> LazyHTML.attribute("name")
      view |> element("##{form_of(view, id)}") |> render_change(%{"_target" => target(name)})
      view |> with_target("##{id}") |> render_hook("posted", %{"changes" => reply.changes})
    end

    view
  end

  # The name the hook's `input` event posts under, as LiveView splits it.
  defp target(name) do
    name
    |> String.replace_suffix("[]", "")
    |> String.split(["[", "]"], trim: true)
  end

  defp form_of(view, id) do
    view
    |> query("form:has(##{id})")
    |> LazyHTML.attribute("id")
    |> List.first() || flunk("#{id} is in no form with an id")
  end

  defp label_of_tag(tag) do
    tag |> LazyHTML.query(".wrap-anywhere:first-child") |> LazyHTML.text() |> String.trim()
  end

  defp new?(option), do: LazyHTML.attribute(option, "data-new") != []

  defp label_of(option) do
    option |> LazyHTML.query("[data-part=label]") |> LazyHTML.text() |> String.trim()
  end

  defp query(view, selector),
    do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp texts(view, selector),
    do: view |> query(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
end
