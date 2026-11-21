defmodule ExampleWeb.FormStateSocketUploadTest do
  @moduledoc """
  A field the form's state holds back takes no file over the socket: what
  arrives for it is cancelled as it comes in, and the save does not consume
  what is still on its way. `ExampleWeb.FormStateScenarioTest` covers the
  external path, where such a field gets no upload target.

  `Example.Test.ShapedOrdersLive.Quick` shows `:photo` only for a gift, and
  its create page draws a stray file input for it while it is hidden.

  Synchronous: `:storage` is global.
  """
  use ExampleWeb.FeatureCase, async: false

  require Ash.Query

  alias Example.Test.ShapedOrders
  alias Example.Test.SocketStore

  @form "form[phx-submit=save]"
  @upload "form[photo]_upload"
  @jpeg File.read!("priv/static/favicon.ico")

  setup %{conn: conn, admin: admin} do
    previous = Application.get_env(:ash_quick, :storage)
    Application.put_env(:ash_quick, :storage, SocketStore)
    on_exit(fn -> Application.put_env(:ash_quick, :storage, previous) end)
    {:ok, conn: log_in(conn, admin)}
  end

  test "a shown field stores what arrives", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/test/shaped_orders/create")
    change(view, %{"code" => unique("O"), "kind" => "gift"}, "kind")

    name = unique("shown") <> ".jpg"
    view |> pick(@form, name) |> render_upload(name)

    assert stored?(name)
  end

  test "a hidden field cancels what arrives for it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/test/shaped_orders/create")
    change(view, %{"code" => unique("O"), "kind" => "standard"}, "kind")

    name = unique("held") <> ".jpg"
    view |> pick("#stray-photo", name) |> render_upload(name)

    refute stored?(name)
    assert upload_entries(view) == []
  end

  # Half a file has arrived while the field was shown. A post that hides it
  # saves without consuming the entry, which, still on its way, could not be.
  test "a field hidden by the save's own post leaves its upload alone", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/test/shaped_orders/create")
    code = unique("O")
    change(view, %{"code" => code, "kind" => "gift"}, "kind")

    name = unique("partial") <> ".jpg"
    view |> pick(@form, name) |> render_upload(name, 50)

    render_submit(view, "save", %{"form" => %{"code" => code, "kind" => "standard"}})

    assert %{kind: :standard, photo: nil} = order(code)
    refute stored?(name)
  end

  defp change(view, params, target) do
    view
    |> form(@form)
    |> render_change(%{"form" => params, "_target" => ["form", target]})
  end

  defp pick(view, form, name) do
    file_input(view, form, @upload, [
      %{name: name, content: @jpeg, type: "image/jpeg", size: byte_size(@jpeg)}
    ])
  end

  defp upload_entries(view), do: :sys.get_state(view.pid).socket.assigns.uploads[@upload].entries

  defp stored?(name) do
    SocketStore.root()
    |> Path.join("**/*#{name}")
    |> Path.wildcard()
    |> Enum.any?()
  end

  defp order(code) do
    ShapedOrders
    |> Ash.Query.filter(code == ^code)
    |> Ash.read_one!(authorize?: false)
  end
end
