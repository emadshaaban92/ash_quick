defmodule ExampleWeb.AttachmentForgeryTest do
  @moduledoc """
  A form post that names an attachment key the form never issued.

  An attachment's type checks only the visibility prefix, so a key is
  accepted on its shape alone. A hand-edited post could point a record at an
  object it has no claim to, such as another record's private file, and the
  page would sign a URL for it, on the next render as much as after a save.

  The keys a form will take are the ones it issued: what the record held when
  the form was built, and what an upload in this LiveView minted. Anything else
  is dropped from the post, whatever shape of field carries it: a single
  attachment (which round-trips through a hidden input), an argument, or an
  attachment inside an embed.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Catalog.Category

  @jpeg File.read!("priv/static/favicon.ico")
  @stolen_private %{"key" => "private/categories/someone-elses.jpg", "file_type" => "image"}
  @stolen_public %{"key" => "public/products/someone-elses.jpg", "file_type" => "image"}

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  describe "a single attachment" do
    test "is not set by a forged hidden input, on validate or on save", ctx do
      %{conn: conn, admin: admin} = ctx

      category =
        admin
        |> category_with_image("private/categories/mine.jpg")

      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}/update")

      html = change(view, %{"image" => Jason.encode!(@stolen_private)})

      # Not even rendered: a preview of the forged key is a signed URL to it.
      refute html =~ "someone-elses"

      submit(view, %{"image" => Jason.encode!(@stolen_private)})

      assert Ash.reload!(category, authorize?: false).image.key == "private/categories/mine.jpg"
    end

    test "keeps its own value across a validate, and takes a fresh pick", ctx do
      %{conn: conn, admin: admin} = ctx
      category = category_with_image(admin, "private/categories/mine.jpg")

      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}/update")

      # The hidden input posts the record's own value back: that one was issued.
      change(view, %{"name" => "Renamed"})
      submit(view, %{"name" => "Renamed"})

      reloaded = Ash.reload!(category, authorize?: false)
      assert reloaded.name == "Renamed"
      assert reloaded.image.key == "private/categories/mine.jpg"

      {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}/update")
      pick(view, "fresh.jpg", "form[image]_upload")
      change(view, %{"name" => "Renamed again"})
      submit(view, %{"name" => "Renamed again"})

      assert Ash.reload!(category, authorize?: false).image.original_filename == "fresh.jpg"
    end

    test "is not set by a forged value on a create form", %{conn: conn} do
      code = unique("C")
      {:ok, view, _html} = live(conn, ~p"/categories/create")

      view
      |> form("form[phx-submit=save]", %{"form" => %{"code" => code, "name" => "Tents"}})
      |> render_submit(%{"form" => %{"image" => Jason.encode!(@stolen_private)}})

      assert Ash.get!(Category, [code: code], authorize?: false).image == nil
    end
  end

  describe "an argument of attachments" do
    test "takes only what was uploaded through the form", %{conn: conn, admin: admin} do
      product = product(actor: admin)

      {:ok, view, _html} = live(conn, ~p"/products/#{product.id}/add_images")
      pick(view, "front.jpg", "form[new_images]_upload")

      view
      |> form("form[phx-submit=save]")
      |> render_submit(%{"form" => %{"new_images" => %{"0" => @stolen_public}}})

      keys = product |> Ash.reload!(authorize?: false) |> Map.get(:images) |> image_keys()

      refute Enum.any?(keys, &(&1 =~ "someone-elses"))
      assert [_front] = keys
    end
  end

  describe "a key from another field" do
    test "is not moved into a field the action accepts", %{conn: conn, admin: admin} do
      # `:add_images` does not accept `:images`, so the record's image key was
      # issued for a field this form cannot write. Posting it into the argument
      # would attach the stored image a second time; across fields of a record
      # with one hidden from the actor, it would hand out that field's object.
      product = product_with_image(admin, "public/products/mine.jpg")

      {:ok, view, _html} = live(conn, ~p"/products/#{product.id}/add_images")

      view
      |> form("form[phx-submit=save]")
      |> render_submit(%{
        "form" => %{"new_images" => %{"0" => %{"key" => "public/products/mine.jpg"}}}
      })

      assert product |> Ash.reload!(authorize?: false) |> Map.get(:images) |> image_keys() ==
               ["public/products/mine.jpg"]
    end
  end

  describe "a hand-sent field named after a relationship" do
    test "is ignored rather than taking the page down", %{conn: conn, admin: admin} do
      # An accepted `category_id` brings the `:category` relationship into the
      # action's fields. Honest forms post the id; this one names the
      # relationship, which has no type to walk.
      product = product(actor: admin)

      {:ok, view, _html} = live(conn, ~p"/products/#{product.id}/update")

      change(view, %{"category" => "x"})
      assert Process.alive?(view.pid)
    end
  end

  describe "an attachment inside an embed" do
    test "is not set by a forged nested input", %{conn: conn, admin: admin} do
      product = product_with_image(admin, "public/products/mine.jpg")

      {:ok, view, _html} = live(conn, ~p"/products/#{product.id}/update")

      html =
        change(view, %{"images" => %{"0" => %{"attachment" => Jason.encode!(@stolen_public)}}})

      refute html =~ "someone-elses"

      submit(view, %{"images" => %{"0" => %{"attachment" => Jason.encode!(@stolen_public)}}})

      assert product |> Ash.reload!(authorize?: false) |> Map.get(:images) |> image_keys() ==
               ["public/products/mine.jpg"]
    end
  end

  defp category_with_image(actor, key) do
    actor
    |> then(&category(actor: &1))
    |> Ash.Changeset.for_update(:update, %{image: %{key: key, file_type: :image}}, actor: actor)
    |> Ash.update!(authorize?: false)
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

  defp image_keys(images), do: Enum.map(images, & &1.attachment.key)

  defp pick(view, filename, upload) do
    view
    |> file_input("form", upload, [
      %{name: filename, content: @jpeg, type: "image/jpeg", size: byte_size(@jpeg)}
    ])
    |> render_upload(filename)
  end

  # Hand-sent: the values ride the event payload rather than the DOM's own
  # inputs, which is what someone editing the page in DevTools would send.
  defp change(view, params) do
    view |> form("form[phx-submit=save]") |> render_change(%{"form" => params})
  end

  defp submit(view, params) do
    view |> form("form[phx-submit=save]") |> render_submit(%{"form" => params})
  end
end
