defmodule ExampleWeb.PresignRefusedBatchTest do
  @moduledoc """
  The host refuses one file of a batch at presign. LiveView marks that entry
  with an upload error but leaves it valid and unfinished, so it has to be
  passed over: waiting on it would never take in the files picked with it,
  and consuming it would take the save down as an entry still in progress.

  Synchronous: `:storage` is global.
  """
  use ExampleWeb.FeatureCase, async: false

  alias Example.Catalog.Category
  alias Example.Test.RefusingArrivalStore

  @upload "form[documents]_upload"
  @jpeg File.read!("priv/static/favicon.ico")

  setup %{conn: conn, admin: admin} do
    previous = Application.get_env(:ash_quick, :storage)
    Application.put_env(:ash_quick, :storage, RefusingArrivalStore)
    on_exit(fn -> Application.put_env(:ash_quick, :storage, previous) end)
    {:ok, conn: log_in(conn, admin)}
  end

  test "a file the host refuses does not hold back the batch, or the save", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/categories/create")
    code = unique("C")

    input =
      file_input(view, "form[phx-submit=save]", @upload, [
        %{name: "good.jpg", content: @jpeg, type: "image/jpeg", size: byte_size(@jpeg)},
        %{name: "refuse.jpg", content: @jpeg, type: "image/jpeg", size: byte_size(@jpeg)}
      ])

    render_upload(input, "refuse.jpg")
    render_upload(input, "good.jpg")

    assert render(view) =~ "This file was refused and has not been uploaded"

    view
    |> form("form[phx-submit=save]", %{"form" => %{"code" => code, "name" => "Tents"}})
    |> render_submit()

    category = Ash.get!(Category, [code: code], authorize?: false)
    assert Enum.map(category.documents, & &1.original_filename) == ["good.jpg"]
  end
end
