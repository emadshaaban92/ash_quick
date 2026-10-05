defmodule ExampleWeb.AttachmentArrayScenarioTest do
  @moduledoc """
  A plain array of attachments on a form: `Category.documents`.

  Unlike `Product.images`, an array of embeds whose every item has inputs of its
  own, a `{:array, :attachment}` attribute has nothing on the page that carries
  its value. The list lives on the server, in the form's params, seeded from the
  record. An upload appends to it, a ✕ removes one position from it, and the
  browser never posts the list itself. Whatever it posts under that name is
  dropped: the field is private, and a key taken from the client would be one
  the details page hands out a signed URL for.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Catalog.Category

  @upload "form[documents]_upload"
  @jpeg File.read!("priv/static/favicon.ico")
  @pdf "%PDF-1.4\n%%EOF\n"

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  describe "the lifecycle of a list" do
    test "uploads append, ✕ removes, and nothing else touches it", %{conn: conn} do
      # 1. Created with one file.
      {:ok, view, _html} = live(conn, ~p"/categories/create")
      code = unique("C")
      pick(view, "a.jpg")
      assert rows(view) == ["a.jpg"]
      save(view, %{"code" => code, "name" => "Tents"})

      category = Ash.get!(Category, [code: code], authorize?: false)
      assert documents(category) == ["a.jpg"]

      # 2. An upload on the update form lands after what is stored, rather than
      #    replacing it.
      view = open(conn, category)
      assert rows(view) == ["a.jpg"]
      pick(view, "b.pdf")
      assert rows(view) == ["a.jpg", "b.pdf"]
      save(view)
      assert documents(category) == ["a.jpg", "b.pdf"]

      # 3. Two batches, in the order they were picked.
      view = open(conn, category)
      pick(view, "c.jpg")
      pick(view, "d.jpg")
      save(view)
      assert documents(category) == ["a.jpg", "b.pdf", "c.jpg", "d.jpg"]

      # 4. A validate round trip between the pick and the save keeps the pick.
      view = open(conn, category)
      pick(view, "e.jpg")
      change(view, %{"name" => "Tents and tarps"})
      assert rows(view) == ["a.jpg", "b.pdf", "c.jpg", "d.jpg", "e.jpg"]
      save(view, %{"name" => "Tents and tarps"})
      assert documents(category) == ["a.jpg", "b.pdf", "c.jpg", "d.jpg", "e.jpg"]

      # 5. ✕ on one position takes it off the page before anything is saved.
      view = open(conn, category)
      remove(view, 1)
      assert rows(view) == ["a.jpg", "c.jpg", "d.jpg", "e.jpg"]
      save(view)
      assert documents(category) == ["a.jpg", "c.jpg", "d.jpg", "e.jpg"]

      # 6. Both in one visit.
      view = open(conn, category)
      remove(view, 0)
      pick(view, "f.pdf")
      assert rows(view) == ["c.jpg", "d.jpg", "e.jpg", "f.pdf"]
      save(view)
      assert documents(category) == ["c.jpg", "d.jpg", "e.jpg", "f.pdf"]

      # 7. Removing every file is a value: the empty list is saved, rather than
      #    the record's own list being put back for want of anything held.
      view = open(conn, category)
      for _ <- 1..4, do: remove(view, 0)
      assert rows(view) == []
      change(view, %{"name" => "Empty"})
      save(view, %{"name" => "Empty"})
      assert documents(category) == []

      # 8. A save that touches another field leaves the list alone.
      view = open(conn, category)
      pick(view, "g.jpg")
      save(view)
      view = open(conn, category)
      save(view, %{"name" => "Renamed"})
      reloaded = Ash.reload!(category, authorize?: false)
      assert reloaded.name == "Renamed"
      assert documents(category) == ["g.jpg"]
    end
  end

  describe "a create form" do
    test "keeps both of two batches, with no record to seed from", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/categories/create")
      code = unique("C")

      pick(view, "a.jpg")
      pick(view, "b.pdf")
      assert rows(view) == ["a.jpg", "b.pdf"]

      save(view, %{"code" => code, "name" => "Tents"})

      assert code |> by_code() |> documents() == ["a.jpg", "b.pdf"]
    end
  end

  describe "a single attachment beside it" do
    test "is still replaced by a new pick", %{conn: conn, admin: admin} do
      category = category(actor: admin)

      view = open(conn, category)
      pick(view, "first.jpg", "form[image]_upload")
      pick(view, "second.jpg", "form[image]_upload")
      save(view)

      assert Ash.reload!(category, authorize?: false).image.original_filename == "second.jpg"
    end
  end

  describe "an argument folded onto an embed array" do
    test "attaches each upload exactly once", %{conn: conn, admin: admin} do
      product = product(actor: admin)

      {:ok, view, _html} = live(conn, ~p"/products/#{product.id}/add_images")
      pick(view, "front.jpg", "form[new_images]_upload")
      save(view)

      assert product |> Ash.reload!(authorize?: false) |> image_names() == ["front.jpg"]

      # On a product that has an image already: the argument is not an array
      # attribute, so nothing stored is seeded into it, and the stored image is
      # not attached a second time.
      {:ok, view, _html} = live(conn, ~p"/products/#{product.id}/add_images")
      pick(view, "back.jpg", "form[new_images]_upload")
      save(view)

      assert product |> Ash.reload!(authorize?: false) |> image_names() ==
               ["front.jpg", "back.jpg"]
    end
  end

  describe "a hand-sent event" do
    setup %{admin: admin} do
      category = category(actor: admin)

      put_documents(category, admin, [
        document("private/categories/mine-a.jpg"),
        document("private/categories/mine-b.pdf")
      ])

      {:ok, category: category}
    end

    test "naming a position or a field that is not there changes nothing", ctx do
      %{conn: conn, category: category} = ctx
      view = open(conn, category)

      for params <- [
            %{"field" => "documents", "index" => "2"},
            %{"field" => "documents", "index" => "-1"},
            %{"field" => "documents", "index" => "one"},
            %{"field" => "documents", "index" => "1.0"},
            %{"field" => "documents", "index" => %{"0" => "1"}},
            %{"field" => "documents"},
            %{"field" => "image", "index" => "0"},
            %{"field" => "name", "index" => "0"},
            %{"field" => "no_such_field_anywhere", "index" => "0"},
            %{"field" => %{"x" => "y"}, "index" => "0"},
            %{}
          ] do
        render_click(view, "remove-attachment", params)
        assert Process.alive?(view.pid)
        assert rows(view) == ["mine-a.jpg", "mine-b.pdf"]
      end

      save(view)
      assert documents(category) == ["mine-a.jpg", "mine-b.pdf"]
    end

    test "on a form the actor may not see is refused", %{conn: conn} do
      # A record the actor cannot read — here, one that does not exist — leaves
      # the form nil and the page on the forbidden panel. An event pushed at it
      # anyway is refused rather than built on nothing.
      {:ok, view, _html} = live(conn, ~p"/categories/#{Ash.UUIDv7.generate()}/update")

      html = render_click(view, "remove-attachment", %{"field" => "documents", "index" => "0"})

      assert html =~ "You do not have permission"
      assert Process.alive?(view.pid)
    end

    test "cannot set the list by posting it, on validate or on save", ctx do
      %{conn: conn, category: category} = ctx
      stolen = %{"key" => "private/categories/someone-elses.jpg", "original_filename" => "x.jpg"}

      view = open(conn, category)

      view
      |> form("form[phx-submit=save]")
      |> render_change(%{"form" => %{"documents" => %{"0" => stolen}}})

      assert rows(view) == ["mine-a.jpg", "mine-b.pdf"]

      view
      |> form("form[phx-submit=save]")
      |> render_submit(%{"form" => %{"documents" => %{"0" => stolen}}})

      assert documents(category) == ["mine-a.jpg", "mine-b.pdf"]
    end

    test "cannot set the list by posting it on a create form", %{conn: conn} do
      stolen = %{"key" => "private/categories/someone-elses.jpg", "original_filename" => "x.jpg"}
      code = unique("C")

      {:ok, view, _html} = live(conn, ~p"/categories/create")

      view
      |> form("form[phx-submit=save]", %{"form" => %{"code" => code, "name" => "Tents"}})
      |> render_submit(%{"form" => %{"documents" => %{"0" => stolen}}})

      assert code |> by_code() |> documents() == []
    end
  end

  describe "the widget" do
    test "shows stored rows beside a file still uploading, and the field's limits", ctx do
      %{conn: conn, admin: admin} = ctx
      category = category(actor: admin)

      put_documents(category, admin, [document("private/categories/stored.pdf", :document)])

      view = open(conn, category)

      # A document row previews as a document, not as a broken image: the host
      # is still holding it, so the placeholder renders — never an `<img>`.
      refute has_element?(view, "[data-attachment-row] img")
      assert has_element?(view, "[data-attachment-row]", "stored.pdf")

      html = render(view)
      assert html =~ "Up to 10 at a time"
      assert html =~ "10.0 MB each"
      assert html =~ ".pdf"
      assert html =~ "Add more documents"

      # Half-uploaded: the stored row stays on the page beside the entry.
      input =
        file_input(view, "form", @upload, [
          %{name: "partway.jpg", content: @jpeg, type: "image/jpeg", size: byte_size(@jpeg)}
        ])

      render_upload(input, "partway.jpg", 50)

      assert rows(view) == ["stored.pdf"]
      assert render(view) =~ "partway.jpg"
    end

    test "an empty list asks for the first one", %{conn: conn, admin: admin} do
      view = open(conn, category(actor: admin))

      assert rows(view) == []
      assert render(view) =~ "Add documents"
    end
  end

  defp open(conn, category) do
    {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}/update")
    view
  end

  # Picks a file the way the browser does. `auto_upload: true`, so this is the
  # whole interaction, and the progress handler folds the file into the form as
  # it lands.
  defp pick(view, filename, upload \\ @upload) do
    type = if Path.extname(filename) == ".pdf", do: "application/pdf", else: "image/jpeg"
    content = if type == "application/pdf", do: @pdf, else: @jpeg

    view
    |> file_input("form", upload, [
      %{name: filename, content: content, type: type, size: byte_size(content)}
    ])
    |> render_upload(filename)
  end

  defp remove(view, index) do
    view
    |> element("[data-attachment-row]:nth-child(#{index + 1}) button[aria-label='Remove']")
    |> render_click()
  end

  defp change(view, params) do
    view |> form("form[phx-submit=save]") |> render_change(%{"form" => params})
  end

  defp save(view, params \\ %{}) do
    view |> form("form[phx-submit=save]", %{"form" => params}) |> render_submit()
  end

  defp rows(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-attachment-row] [data-attachment-name]")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp put_documents(category, actor, documents) do
    category
    |> Ash.Changeset.for_update(:update, %{documents: documents}, actor: actor)
    |> Ash.update!(authorize?: false)
  end

  defp by_code(code), do: Ash.get!(Category, [code: code], authorize?: false)

  defp documents(%Category{} = category) do
    category
    |> Ash.reload!(authorize?: false)
    |> Map.get(:documents)
    |> List.wrap()
    |> Enum.map(& &1.original_filename)
  end

  defp image_names(product), do: Enum.map(product.images, & &1.attachment.original_filename)

  defp document(key, file_type \\ nil) do
    file_type = file_type || if(Path.extname(key) == ".pdf", do: :document, else: :image)

    %{
      key: key,
      file_type: file_type,
      original_filename: Path.basename(key)
    }
  end
end
