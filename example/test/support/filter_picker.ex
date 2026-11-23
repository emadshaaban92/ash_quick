defmodule ExampleWeb.FilterPicker do
  @moduledoc """
  Drives the picker a filter row picks Any Of and Has Any Of values with, the
  way its hook does in a browser, through `ExampleWeb.PickerDriver`.

  Each takes the LiveView and the row's uuid. `pick_values/3` and
  `remove_value/3` return the view; the others return labels. An option or a
  tag reads as all its text, a record's hint under its name included, and is
  matched by that text with its runs of whitespace taken as one space.
  """

  import ExUnit.Assertions
  import Phoenix.LiveViewTest

  alias ExampleWeb.PickerDriver

  @doc "The id of the row's picker, or `nil` when the row draws none."
  def picker_id(view, uuid) do
    view
    |> query("[data-aq-picker][id^='filter-values-#{uuid}-']")
    |> LazyHTML.attribute("id")
    |> List.first()
  end

  @doc "The labels of the row's tags, in order."
  def picked(view, uuid),
    do: texts(view, "##{picker!(view, uuid)} [data-part=tag] > :first-child")

  @doc """
  Opens the row's list with nothing typed, as clicking into it does, and
  returns the labels it offers.
  """
  def focus_values(view, uuid) do
    PickerDriver.search(view, picker!(view, uuid), "")
    offered(view, uuid)
  end

  @doc "Types `text` into the row's input, and returns the labels offered."
  def search_values(view, uuid, text) do
    PickerDriver.search(view, picker!(view, uuid), text)
    offered(view, uuid)
  end

  @doc "The labels the row's open list offers."
  def offered(view, uuid),
    do: texts(view, "##{picker!(view, uuid)}-listbox [role=option] > :last-child")

  @doc """
  Picks each of `labels` from the row's list, and posts each pick. Each is
  picked from the list opened afresh, or with `searched: true` from the one a
  search left open, which opening it again would clear.
  """
  def pick_values(view, uuid, labels, opts \\ []) do
    for label <- labels do
      unless opts[:searched], do: focus_values(view, uuid)
      id = picker!(view, uuid)

      value = value_of(view, "##{id}-listbox [role=option]", ":last-child", label)
      assert value, "#{inspect(label)} is not offered: #{inspect(offered(view, uuid))}"
      PickerDriver.pick(view, id, value: value)
    end

    view
  end

  @doc "Removes the tag labelled `label` by its ✕, and posts what is left."
  def remove_value(view, uuid, label) do
    id = picker!(view, uuid)

    value = value_of(view, "##{id} [data-part=tag]", ":first-child", label)
    assert value, "no tag #{inspect(label)}: #{inspect(picked(view, uuid))}"
    PickerDriver.remove(view, id, value: value)
  end

  defp picker!(view, uuid) do
    picker_id(view, uuid) || flunk("row #{uuid} draws no picker")
  end

  defp query(view, selector),
    do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp texts(view, selector),
    do: view |> query(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

  # The value of the first of `items` whose `part` (a child of it) reads as
  # `label`.
  defp value_of(view, items, part, label) do
    values = view |> query(items) |> LazyHTML.attribute("data-value")
    labels = view |> query("#{items} > #{part}") |> Enum.map(&(&1 |> LazyHTML.text() |> squash()))

    Enum.find_value(Enum.zip(labels, values), fn {text, value} ->
      if text == squash(label), do: value
    end)
  end

  defp squash(text), do: text |> String.trim() |> String.replace(~r/\s+/, " ")
end
