defmodule AshQuick.LiveView.PrepareAssignsTest do
  @moduledoc """
  What the generic templates render from has to live on the socket.

  These assigns used to be computed inside `render/1`. A key assigned during a
  render is never stored on the socket, so the next render found it absent and
  change tracking marked it changed every time — re-rendering every part of
  the list that reads `@fields`, `@path_for_page` or `@id`, every row included,
  on every event, whatever the event was about.

  Assigned in `handle_params/3`, a key is marked changed only when its value
  differs, so these pin exactly that: a second pass over the same URL changes
  nothing, and one over a different page changes only what the page decides.
  """
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.QuickView
  alias AshQuick.LiveView.QuickView.Options
  alias AshQuick.LiveView.URLParams
  alias AshQuick.Test.Lookup.OtherName

  @path "/other_names"

  setup do
    options = Options.new(__MODULE__.SomeQuickView, OtherName, resource: OtherName)
    action = Ash.Resource.Info.action(OtherName, options.list_default_action)

    {:ok, options: options, action: action}
  end

  defp socket(params) do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, path: @path, params: params}
    }
  end

  # What a render leaves behind: the socket keeps its assigns and forgets
  # which of them changed.
  defp rendered(socket), do: put_in(socket.assigns.__changed__, %{})

  test "the list's assigns are stored on the socket", %{options: options, action: action} do
    socket = QuickView.prepare_assigns(socket(%URLParams{}), action, options)

    assert socket.assigns.fields == options.list_fields
    assert socket.assigns.id =~ "-list"
    assert socket.assigns.path_for_page.(3) =~ "page=3"
    assert is_function(socket.assigns.new_click, 0)
  end

  test "preparing the same URL again marks nothing changed",
       %{options: options, action: action} do
    socket =
      socket(%URLParams{})
      |> QuickView.prepare_assigns(action, options)
      |> rendered()
      |> QuickView.prepare_assigns(action, options)

    assert socket.assigns.__changed__ == %{}
  end

  test "moving to another page changes the pager, not the columns",
       %{options: options, action: action} do
    socket =
      socket(%URLParams{})
      |> QuickView.prepare_assigns(action, options)
      |> rendered()

    socket =
      %{socket | assigns: %{socket.assigns | params: %URLParams{page: 2}}}
      |> QuickView.prepare_assigns(action, options)

    assert Map.has_key?(socket.assigns.__changed__, :path_for_page)
    refute Map.has_key?(socket.assigns.__changed__, :fields)
    refute Map.has_key?(socket.assigns.__changed__, :id)
    refute Map.has_key?(socket.assigns.__changed__, :new_click)
  end
end
