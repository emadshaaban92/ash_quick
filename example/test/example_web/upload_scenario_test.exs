defmodule ExampleWeb.UploadScenarioTest do
  @moduledoc """
  Picking a file on a form, and what the host is holding afterwards.

  The ordering is the whole point and it is not the obvious one. Uploads are
  `auto_upload: true`, so the bytes are in storage the moment a file is
  *picked* — long before anybody presses Save, and whether or not they ever do.
  An application that heard about an object at save time would never hear about
  the ones nobody saved, which is most of them.

  So custody is taken at **presign**: `Example.Uploads.ObjectStore.object_arriving/2`
  opens a row, routes the bytes to `Example.Uploads.Quarantine`, and the key the
  browser is sent to is not the key the record will hold. `object_referenced/3`
  is the only signal that anything ever came back for it, which is what makes an
  abandoned upload distinguishable from a live one rather than invisible.

  `AshQuick.LiveView.FormUtilsTest` pins what is not visible on a page — the key
  derivation, the signed `Content-Length`, and a host refusing an object outright
  (which fails the entry rather than signing a URL for it). This is the rest:
  what a person does, and what it leaves behind.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Catalog.Category
  alias Example.Uploads.{FileObject, Quarantine}

  @upload "form[image]_upload"
  @jpeg File.read!("priv/static/favicon.ico")

  describe "picking a file" do
    test "takes custody before anything is saved, and quarantines the bytes", ctx do
      %{conn: conn, admin: admin} = ctx

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/categories/create")

      pick(view, "tent.jpg")

      # A row exists although nothing has been submitted and no category exists.
      assert [object] = uploaded_objects(admin)
      assert object.state == :processing
      assert object.original_filename == "tent.jpg"
      assert object.resource_name == :category
      assert is_nil(object.resource_id)
      assert is_nil(object.referenced_at)

      # The row is keyed by the *serving* key. The bytes are somewhere else
      # until something releases them, and nothing has.
      assert object.key =~ "private/categories/"
      refute Quarantine.quarantined?(object.key)
    end

    test "records what the field would have accepted, which the key cannot say", ctx do
      %{conn: conn, admin: admin} = ctx

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/categories/create")

      pick(view, "tent.jpg")

      # Copied off the attribute's constraints at presign because they cannot be
      # recovered later: a key alone does not say which Ash type produced it.
      assert [object] = uploaded_objects(admin)
      assert object.accepts == [:image]
      assert object.max_bytes == 10 * 1024 * 1024
    end
  end

  describe "saving the form" do
    test "is what marks the object referenced, and names the record", ctx do
      %{conn: conn, admin: admin} = ctx

      code = unique("C")

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/categories/create")

      pick(view, "tent.jpg")

      view
      |> form("#category-create", %{"form" => %{"code" => code, "name" => "Tents"}})
      |> render_submit()

      category = Ash.get!(Category, [code: code], authorize?: false)

      assert [object] = uploaded_objects(admin)
      refute is_nil(object.referenced_at)
      assert object.resource_id == category.id

      # And the record holds the serving key, so the two directions agree.
      assert category.image.key == object.key
    end

    test "leaves an abandoned pick unreferenced, which is how it is found later", ctx do
      %{conn: conn, admin: admin} = ctx

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/categories/create")

      pick(view, "never-saved.jpg")

      # The reader closes the tab. Nothing about the object changes, and the
      # absence of `referenced_at` is the whole record of that.
      assert [object] = uploaded_objects(admin)
      assert is_nil(object.referenced_at)
      assert object.state == :processing

      # It is not attached to anything, which is the question a cleanup job asks.
      assert Ash.count!(Category, authorize?: false) == 0
    end
  end

  describe "the object console" do
    test "shows what the storage seam is holding, and how far along it is", ctx do
      %{conn: conn, admin: admin} = ctx

      processing = file_object(filename: "still-going.jpg", actor: admin)
      released = file_object(filename: "served.jpg", actor: admin)
      FileObject.release!(released, authorize?: false)

      conn
      |> log_in(admin)
      |> visit(~p"/file_objects")
      |> assert_has("td", text: processing.key)
      |> assert_has("td", text: released.key)
      # `:state` is the column the page exists for.
      |> assert_has("td", text: "Processing")
      |> assert_has("td", text: "Ready")
      # Routed `only: [:index, :show]` — a row appears when a file is picked,
      # not when somebody fills in a form.
      |> refute_has("button[phx-click*='new_click']")
    end

    test "names who uploaded each one", ctx do
      %{conn: conn, admin: admin, editor: editor} = ctx

      object = file_object(filename: "theirs.jpg", actor: editor)

      conn
      |> log_in(admin)
      |> visit(~p"/file_objects/#{object.id}")
      |> assert_has("h1", text: object.key)
      |> assert_has("dd", text: editor.name)
      |> assert_has("dd", text: "Processing")
    end

    test "offers no control for the action the page cannot serve", ctx do
      %{conn: conn, admin: admin} = ctx

      object = file_object(actor: admin)

      # `:reference` is stamped by the pipeline with `authorize?: false` and by
      # nothing else. Left authorizable it would render as a button that patches
      # to `/file_objects/:id/reference`, a route this read-only page does not
      # serve — which is exactly what `mix ash_quick.check` reports.
      conn
      |> log_in(admin)
      |> visit(~p"/file_objects/#{object.id}")
      |> refute_has("button", text: "Reference")
      |> refute_has("a", text: "Reference")

      refute Ash.can?({object, :reference}, admin)
    end
  end

  describe "the row for a key" do
    test "is exactly one row, however many times the key is presented", ctx do
      %{conn: conn, admin: admin} = ctx

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/categories/create")

      pick(view, "tent.jpg")

      assert [object] = uploaded_objects(admin)

      # `take_custody` upserts on the key, because a surface may present the
      # same one more than once — a re-render, a reconnect — and "the row for
      # key K" has to stay singular for `object_states/1` to answer at all.
      assert {:ok, [^object]} = FileObject.by_keys([object.key], authorize?: false)
    end
  end

  # Picks a file the way the browser does. `auto_upload: true`, so this is the
  # whole interaction — there is no separate "start upload" step, and the
  # presign happens here.
  defp pick(view, filename) do
    view
    |> file_input("form", @upload, [
      %{name: filename, content: @jpeg, type: "image/jpeg", size: byte_size(@jpeg)}
    ])
    |> render_upload(filename)
  end

  defp uploaded_objects(actor) do
    FileObject
    |> Ash.read!(actor: actor, authorize?: false)
    |> Enum.sort_by(& &1.id)
  end
end
