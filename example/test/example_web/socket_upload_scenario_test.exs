defmodule ExampleWeb.SocketUploadScenarioTest do
  @moduledoc """
  A storage module without `upload_target/2` takes a picked file over the
  LiveView socket, and AshQuick stores it with `put_file/3` once it arrives.
  `ExampleWeb.UploadScenarioTest` covers the external path the example's own
  store uses.

  Synchronous: `:storage` is global, so swapping it would leak into every case
  running alongside.
  """
  use ExampleWeb.FeatureCase, async: false

  alias Example.Catalog.Category
  alias Example.Test.SocketStore

  @upload "form[image]_upload"
  @jpeg File.read!("priv/static/favicon.ico")

  setup do
    previous = Application.get_env(:ash_quick, :storage)
    Application.put_env(:ash_quick, :storage, SocketStore)
    on_exit(fn -> Application.put_env(:ash_quick, :storage, previous) end)
  end

  test "stores the file through put_file/3 and saves its key on the record", ctx do
    %{conn: conn, admin: admin} = ctx
    code = unique("C")

    {:ok, view, _html} = live(log_in(conn, admin), ~p"/categories/create")

    pick(view, "tent.jpg")

    view
    |> form("#category-create", %{"form" => %{"code" => code, "name" => "Tents"}})
    |> render_submit()

    category = Ash.get!(Category, [code: code], authorize?: false)

    assert category.image.key =~ ~r{^private/categories/.+-tent\.jpg$}
    assert category.image.original_filename == "tent.jpg"
    assert SocketStore.read(category.image.key) == @jpeg
  end

  test "says so when the store refuses the file, and saves nothing for it", ctx do
    %{conn: conn, admin: admin} = ctx

    {:ok, view, _html} = live(log_in(conn, admin), ~p"/categories/create")

    html = pick(view, "refuse-me.jpg")

    assert html =~ "This file was refused and has not been uploaded"

    refute SocketStore.root()
           |> Path.join("**/*refuse-me.jpg")
           |> Path.wildcard()
           |> Enum.any?()
  end

  # The refusal is the only trace the pick leaves, so typing elsewhere in the
  # form must not take it down before it is read. Acting on the upload does.
  test "keeps the refusal up while the form is edited, until a file is picked again", ctx do
    %{conn: conn, admin: admin} = ctx

    {:ok, view, _html} = live(log_in(conn, admin), ~p"/categories/create")

    pick(view, "refuse-me.jpg")

    html =
      view
      |> form("#category-create", %{"form" => %{"name" => "Tents"}})
      |> render_change(%{"_target" => ["form", "name"]})

    assert html =~ "This file was refused and has not been uploaded"

    refute pick(view, "tent.jpg") =~ "This file was refused and has not been uploaded"
  end

  # A sub-form's upload is not taken when it lands: it is consumed by the save,
  # which is where the store refuses it.
  test "says so when the store refuses a sub-form's file at save", ctx do
    %{conn: conn, admin: admin} = ctx
    product = product_with_image(admin, "public/products/mine.jpg")

    {:ok, view, _html} = live(log_in(conn, admin), ~p"/products/#{product.id}/update")
    view |> element("[phx-click=add-form][phx-value-path='form[images]']") |> render_click()
    pick(view, "refuse-me.jpg", "form[images][1][attachment]_upload")

    view
    |> form("form[phx-submit=save]")
    |> render_submit(%{"form" => %{"name" => "Renamed"}})

    # The save went on, so the page moved to the record; the flash came along.
    assert render(view) =~ "This file was refused and has not been uploaded"

    reloaded = Ash.reload!(product, authorize?: false)
    assert reloaded.name == "Renamed"
    # The added image row is saved, empty: its file is what was refused.
    assert Enum.map(reloaded.images, &(&1.attachment && &1.attachment.key)) ==
             ["public/products/mine.jpg", nil]
  end

  describe "an external store whose upload meta names a path" do
    setup do
      Application.put_env(:ash_quick, :storage, Example.Test.PathMetaStore)
    end

    test "is still read as external, so nothing is stored a second time", ctx do
      %{conn: conn, admin: admin} = ctx
      code = unique("C")

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/categories/create")

      refute pick(view, "tent.jpg") =~ "This file was refused"

      view
      |> form("#category-create", %{"form" => %{"code" => code, "name" => "Tents"}})
      |> render_submit()

      category = Ash.get!(Category, [code: code], authorize?: false)
      assert category.image.key =~ ~r{^private/categories/.+-tent\.jpg$}
    end
  end

  defp pick(view, filename, upload \\ @upload) do
    view
    |> file_input("form[phx-submit=save]", upload, [
      %{name: filename, content: @jpeg, type: "image/jpeg", size: byte_size(@jpeg)}
    ])
    |> render_upload(filename)

    render(view)
  end

  defp product_with_image(actor, key) do
    [actor: actor]
    |> product()
    |> Ash.Changeset.for_update(
      :update,
      %{images: [%{attachment: %{key: key, file_type: :image}}]},
      actor: actor
    )
    |> Ash.update!(authorize?: false)
  end
end
