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

  # Refused on its name before any of its bytes are sent, with the same
  # message the external path gives.
  test "refuses a name the field does not take, whatever type it declares", ctx do
    %{conn: conn, admin: admin} = ctx
    code = unique("C")
    stored_before = stored_files()

    {:ok, view, _html} = live(log_in(conn, admin), ~p"/categories/create")

    assert pick(view, "evil.html") =~ "You have selected an unacceptable file type"

    view
    |> form("#category-create", %{"form" => %{"code" => code, "name" => "Tents"}})
    |> render_submit()

    assert Ash.get!(Category, [code: code], authorize?: false).image == nil
    assert stored_files() == stored_before
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

  # A socket upload's key is made when the save consumes the entry, not at
  # presign. The failed save leaves it in the sub-form's hidden input, which
  # the next post names back, so the form must count it as one it issued.
  test "keeps a sub-form's file across a save that fails", ctx do
    %{conn: conn, admin: admin} = ctx
    product = product_with_image(admin, "public/products/mine.jpg")

    {:ok, view, _html} = live(log_in(conn, admin), ~p"/products/#{product.id}/update")
    view |> element("[phx-click=add-form][phx-value-path='form[images]']") |> render_click()
    pick(view, "fresh.jpg", "form[images][1][attachment]_upload")

    submit(view, %{"name" => ""})
    submit(view, %{"name" => "Renamed"})

    reloaded = Ash.reload!(product, authorize?: false)
    assert reloaded.name == "Renamed"
    assert ["public/products/mine.jpg", fresh] = image_keys(reloaded.images)
    assert fresh =~ "fresh.jpg"
    assert SocketStore.read(fresh) == @jpeg
  end

  # Removing a row renumbers the rows after it. A file picked on one of them
  # goes with its row, and the removed row's file goes nowhere.
  describe "removing a sub-form row" do
    test "keeps a later row's file on that row", ctx do
      %{conn: conn, admin: admin} = ctx
      product = product_with_image(admin, "public/products/mine.jpg")

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/products/#{product.id}/update")
      add_image_row(view)
      add_image_row(view)
      pick(view, "kept.jpg", "form[images][2][attachment]_upload")

      remove_image_row(view, 1)
      submit(view, %{"name" => "Renamed"})

      reloaded = Ash.reload!(product, authorize?: false)
      assert reloaded.name == "Renamed"
      assert ["public/products/mine.jpg", kept] = image_keys(reloaded.images)
      assert kept =~ "kept.jpg"
    end

    test "drops the removed row's file rather than moving it to the next row", ctx do
      %{conn: conn, admin: admin} = ctx
      product = product_with_image(admin, "public/products/mine.jpg")

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/products/#{product.id}/update")
      add_image_row(view)
      add_image_row(view)
      pick(view, "removed.jpg", "form[images][1][attachment]_upload")

      remove_image_row(view, 1)
      submit(view, %{"name" => "Renamed"})

      reloaded = Ash.reload!(product, authorize?: false)
      assert reloaded.name == "Renamed"
      assert image_keys(reloaded.images) == ["public/products/mine.jpg", nil]
    end

    test "gives a row added after the removal an upload of its own", ctx do
      %{conn: conn, admin: admin} = ctx
      product = product_with_image(admin, "public/products/mine.jpg")

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/products/#{product.id}/update")
      add_image_row(view)
      add_image_row(view)
      pick(view, "kept.jpg", "form[images][2][attachment]_upload")
      remove_image_row(view, 1)

      # Named `form[images][2]`, as the row that kept its file was.
      add_image_row(view)
      refute image_upload(view, 2) == image_upload(view, 1)
      pick(view, "added.jpg", image_upload(view, 2))

      submit(view, %{"name" => "Renamed"})

      reloaded = Ash.reload!(product, authorize?: false)
      assert ["public/products/mine.jpg", kept, added] = image_keys(reloaded.images)
      assert kept =~ "kept.jpg"
      assert added =~ "added.jpg"
    end

    test "takes a file picked on a row after the removal", ctx do
      %{conn: conn, admin: admin} = ctx
      product = product_with_image(admin, "public/products/mine.jpg")

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/products/#{product.id}/update")
      add_image_row(view)
      add_image_row(view)
      remove_image_row(view, 1)
      # The row now second keeps the upload it was given as the third.
      pick(view, "later.jpg", image_upload(view, 1))

      submit(view, %{"name" => "Renamed"})

      reloaded = Ash.reload!(product, authorize?: false)
      assert ["public/products/mine.jpg", later] = image_keys(reloaded.images)
      assert later =~ "later.jpg"
    end
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

  # Compared before and after rather than matched by name: the store's root
  # outlives a run, so a file an earlier run left there must not count.
  defp stored_files do
    SocketStore.root() |> Path.join("**/*") |> Path.wildcard() |> Enum.sort()
  end

  defp pick(view, filename, upload \\ @upload) do
    view
    |> file_input("form[phx-submit=save]", upload, [
      %{name: filename, content: @jpeg, type: "image/jpeg", size: byte_size(@jpeg)}
    ])
    |> render_upload(filename)

    render(view)
  end

  defp submit(view, params) do
    view |> form("form[phx-submit=save]") |> render_submit(%{"form" => params})
  end

  defp add_image_row(view) do
    view |> element("[phx-click=add-form][phx-value-path='form[images]']") |> render_click()
  end

  defp remove_image_row(view, index) do
    render_click(view, "remove-form", %{"path" => "form[images][#{index}]"})
  end

  # The upload behind the file input the page draws on that image row.
  defp image_upload(view, row) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(input[type="file"][name^="form[images]"]))
    |> LazyHTML.attribute("name")
    |> Enum.at(row)
  end

  defp image_keys(images), do: Enum.map(images, &(&1.attachment && &1.attachment.key))

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
