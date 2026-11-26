defmodule ExampleWeb.Browser.DetailsPageTest do
  @moduledoc """
  What a details page does in a real browser: its image viewer
  (`AshQuick.Components.attachment_viewer/1`), a modal carousel whose
  previews open it on their own slide, whose buttons and arrow keys step
  through the slides, and wrap, and whose arrows follow the reading
  direction; and the Copy button beside a stored map's Raw JSON.

  The images' URLs are presigned for a bucket nobody can reach from here, so
  a Playwright route answers them with a small image.
  """
  use ExampleWeb.BrowserCase,
    parameterize: [%{locale: :en}, %{locale: :ar}]

  alias Example.Test.StoredMapLists

  @image File.read!("priv/static/favicon.ico")

  setup %{locale: locale} do
    %{admin: admin} = roles()
    admin = Ash.update!(admin, %{locale: locale}, authorize?: false)
    %{admin: admin}
  end

  describe "the image viewer" do
    setup %{admin: admin} do
      keys = for name <- ~w(front side back), do: "private/categories/#{unique(name)}.jpg"

      category =
        [actor: admin]
        |> category()
        |> Ash.Changeset.for_update(
          :update,
          %{documents: Enum.map(keys, &%{key: &1, file_type: :image, original_filename: &1})},
          actor: admin
        )
        |> Ash.update!(authorize?: false)

      %{category: category, keys: keys}
    end

    defp open_details(conn, admin, category) do
      {:ok, _} =
        PlaywrightEx.BrowserContext.route(
          conn.context_id,
          "**/private/categories/**",
          fn route, _request ->
            {:ok, _} =
              PlaywrightEx.Route.fulfill(route, body: @image, content_type: "image/x-icon")
          end,
          timeout: 5_000
        )

      conn
      |> log_in(admin)
      |> visit(~p"/categories/#{category.id}")
      |> connected()
    end

    # The slide shown is the one whose Open link has the focus.
    defp shown(conn, key), do: assert_has(conn, ~s([data-attachment-slide="#{key}"] a:focus))

    # The viewer a preview opens.
    defp viewer(conn, key),
      do:
        read(
          conn,
          ~s|document.querySelector('[data-attachment-view="#{key}"]').dataset.attachmentViewer|
        )

    test "a preview opens it on its own image, and its buttons step through them, round",
         %{conn: conn, admin: admin, category: category, keys: [front, side, back]} do
      conn =
        conn
        |> open_details(admin, category)
        |> click(~s([data-attachment-view="#{side}"]))
        |> shown(side)

      dialog = viewer(conn, side)
      assert read(conn, "document.getElementById('#{dialog}').matches(':modal')")

      conn
      |> click("##{dialog} button[data-step='1']")
      |> shown(back)
      |> click("##{dialog} button[data-step='1']")
      |> shown(front)
      |> click("##{dialog} button[data-step='-1']")
      |> shown(back)
      |> click("##{dialog} button.btn-circle[data-close]")
      |> tap(&refute(read(&1, "document.getElementById('#{dialog}').open")))
    end

    test "its arrow keys step the way the page reads",
         %{conn: conn, admin: admin, category: category, keys: [front, side, back]} = ctx do
      {forward, backward} =
        if ctx.locale == :ar, do: {"ArrowLeft", "ArrowRight"}, else: {"ArrowRight", "ArrowLeft"}

      conn
      |> open_details(admin, category)
      |> click(~s([data-attachment-view="#{front}"]))
      |> shown(front)
      |> press(":focus", forward)
      |> shown(side)
      |> press(":focus", forward)
      |> shown(back)
      |> press(":focus", backward)
      |> shown(side)
      # A modified arrow is the browser's.
      |> press(":focus", "Alt+#{forward}")
      |> shown(side)
    end

    test "Escape closes it, and it opens again on another image",
         %{conn: conn, admin: admin, category: category, keys: [front, _side, back]} do
      conn =
        conn
        |> open_details(admin, category)
        |> click(~s([data-attachment-view="#{back}"]))
        |> shown(back)

      dialog = viewer(conn, back)

      conn
      |> press(":focus", "Escape")
      |> tap(&refute(read(&1, "document.getElementById('#{dialog}').open")))
      |> click(~s([data-attachment-view="#{front}"]))
      |> shown(front)
    end
  end

  describe "a stored map's Raw JSON" do
    @describetag browser_context_opts: [permissions: ["clipboard-read", "clipboard-write"]]

    test "Copy puts it on the clipboard, and says so for a moment", %{conn: conn, admin: admin} do
      record =
        StoredMapLists
        |> Ash.Changeset.for_create(:create, %{code: unique("M")})
        |> Ash.Changeset.force_change_attribute(:entries, [%{"size" => "large", "count" => 2}])
        |> Ash.create!(authorize?: false)

      conn =
        conn
        |> log_in(admin)
        |> visit("/test/stored_map_lists/#{record.id}")
        |> connected()
        |> click("[data-stored-map=details] > details > summary")

      copy = read(conn, "document.querySelector('button[data-copy-from]').id")

      raw =
        read(
          conn,
          "document.getElementById(document.getElementById('#{copy}').dataset.copyFrom).textContent"
        )

      assert raw =~ ~s("size")

      conn
      |> click("##{copy}")
      |> assert_has("##{copy} [role=status]")
      |> tap(&assert(read(&1, "navigator.clipboard.readText()") == raw))
      # It goes back to "Copy".
      |> refute_has("##{copy} [role=status]")
    end
  end
end
