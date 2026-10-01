defmodule AshQuick.LiveView.Components.ListViewDiffTest do
  @moduledoc """
  What a list re-sends when an event touches none of it.

  `ListView.list_view/1` is called with the LiveView's own assigns, so anything
  it assigns is a key the socket never holds — marked changed on every render,
  and with it every part of the template that reads it. It used to assign
  `:rows`, `:meta`, `:current_page`, `:pages_count` and `:filtered_actions`
  that way, so every event re-rendered the rows and the pager whatever it was
  about. The rows were re-rendered but not re-sent, since a keyed comprehension
  compares each row with what the client holds; the pager was re-sent. These
  render the list twice through `Phoenix.LiveView.Diff`, the way a LiveView
  does, and look at what the second diff carries.
  """
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.Components.ListView
  alias AshQuick.LiveView.QuickView
  alias AshQuick.LiveView.QuickView.Options
  alias AshQuick.LiveView.URLParams
  alias AshQuick.Test.Lookup.OtherName
  alias Phoenix.LiveView.Diff

  setup do
    options = Options.new(__MODULE__.SomeQuickView, OtherName, resource: OtherName)
    action = Ash.Resource.Info.action(OtherName, options.list_default_action)

    assigns = %{
      __changed__: %{},
      resource: OtherName,
      scope: nil,
      path: "/other_names",
      base_path: "/other_names",
      params: %URLParams{},
      routed_shapes: [],
      filters: nil,
      selected_rows: %{},
      action_running: false,
      row_actions: nil,
      export_data: nil,
      print_data: nil,
      data: %{
        results: [
          %OtherName{id: "row-one", name: "Alpha Row Name"},
          %OtherName{id: "row-two", name: "Beta Row Name"}
        ],
        count: 2,
        limit: 20,
        offset: 0
      }
    }

    socket =
      %Phoenix.LiveView.Socket{assigns: assigns}
      |> QuickView.prepare_assigns(action, options)

    {:ok, socket: socket}
  end

  defp render_diff(socket, prints) do
    rendered = ListView.list_view(socket.assigns)
    {diff, prints, _components} = Diff.render(socket, rendered, prints, Diff.new_components())
    {inspect(diff, limit: :infinity, printable_limit: :infinity), prints}
  end

  # What a render leaves behind: the socket keeps its assigns and forgets
  # which of them changed.
  defp rendered(socket), do: put_in(socket.assigns.__changed__, %{})

  test "an event the list does not read re-sends neither its rows nor its pager",
       %{socket: socket} do
    {first, prints} = render_diff(socket, Diff.new_fingerprints())

    assert first =~ "Alpha Row Name"
    assert first =~ "Showing"

    # A bulk action starting: an event that changes one assign the table and
    # the pager never read.
    socket = socket |> rendered() |> Phoenix.Component.assign(:action_running, true)
    {second, _prints} = render_diff(socket, prints)

    refute second =~ "Alpha Row Name"
    refute second =~ "Beta Row Name"
    refute second =~ "Showing"
  end

  test "a change to the page's data still re-sends the rows", %{socket: socket} do
    {_first, prints} = render_diff(socket, Diff.new_fingerprints())

    data = %{socket.assigns.data | results: [%OtherName{id: "row-three", name: "Gamma Row Name"}]}
    socket = socket |> rendered() |> Phoenix.Component.assign(:data, data)
    {second, _prints} = render_diff(socket, prints)

    assert second =~ "Gamma Row Name"
  end
end
