defmodule ExampleWeb.Browser.DownloadsTest do
  @moduledoc """
  The files actions hand the browser, in a real one: a file an action
  produced (`ash_quick:download`, `assets/js/download.js`) and a printed PDF
  (`ash_quick:pdf`, `assets/js/print.js`), saved or sent to the print dialog.
  The server's half, which event carries what, is
  `ExampleWeb.PrintScenarioTest`'s and the download scenarios'; these read
  what the tab does with the event.
  """
  use ExampleWeb.BrowserCase

  alias Example.Test.{Downloadable, Printable}
  alias Example.Test.Downloadable.Watermark

  @modal "#ash-quick-action-modal"

  setup do
    %{admin: admin} = roles()
    %{admin: admin}
  end

  defp run_row_action(conn, id, action) do
    conn
    |> click(~s([id="#{id}-row-actions-dropdown-trigger"]))
    |> click(~s([id="#{id}-action-#{action}"]))
    |> click("#{@modal} form button[type=submit]")
  end

  test "a file an action produced is saved under the name it gave, byte for byte",
       %{conn: conn, admin: admin} do
    record =
      Ash.create!(Downloadable, %{code: unique("D"), name: unique("Northwind ")},
        authorize?: false
      )

    conn
    |> log_in(admin)
    |> visit("/test/downloadable")
    |> connected()
    |> run_row_action(record.id, "watermark")
    |> assert_download(fn download ->
      assert download.name == Watermark.filename(record)
      assert download.content == Watermark.bytes(record)
    end)
  end

  test "a printed PDF to download is saved, named for the record",
       %{conn: conn, admin: admin} do
    record =
      Ash.create!(Printable, %{code: unique("P"), name: unique("Globex ")}, authorize?: false)

    conn
    |> log_in(admin)
    |> visit("/test/printable")
    |> connected()
    |> run_row_action(record.id, "print")
    |> assert_download(fn download ->
      assert download.name =~ ~r/\.pdf$/
      assert "%PDF-1.4\n" <> html = download.content
      assert html =~ record.name
    end)
  end

  test "a printed PDF to print goes to the print dialog from a frame off the screen",
       %{conn: conn, admin: admin} do
    record =
      Ash.create!(Printable, %{code: unique("P"), name: unique("Initech ")}, authorize?: false)

    conn =
      conn
      |> log_in(admin)
      |> visit("/test/printable/#{record.id}")
      |> connected()

    # The frame print.js adds, as it is added: where it is drawn and what it
    # holds. Chromium's headless shell has no PDF viewer, so the frame's
    # document never loads; its `load` is fired here instead, once the frame's
    # window has a stand-in for the print dialog.
    read(conn, """
    (() => {
      window.frames_added = []
      new MutationObserver(records => records.forEach(record => record.addedNodes.forEach(node => {
        if (node.tagName !== "IFRAME") return
        const frame = {src: node.src, left: node.style.left, position: node.style.position}
        window.frames_added.push(frame)
        fetch(node.src).then(r => r.text()).then(text => frame.text = text)
        node.contentWindow.print = () => document.body.dataset.printed = node.src
        node.dispatchEvent(new Event("load"))
      }))).observe(document.body, {childList: true})
      return true
    })()
    """)

    conn
    |> click("#details-more-actions-dropdown-trigger")
    |> click("#details-more-actions-dropdown [role=menuitem]", "Rename And Print")
    |> fill_in("Name", with: "#{record.name} renamed")
    |> click("#{@modal} form button[type=submit]")
    |> assert_has("h1", text: "renamed")
    |> assert_has("body[data-printed^='blob:']")
    |> assert_has("iframe[src^='blob:']")
    |> then(fn conn ->
      assert [frame] = read(conn, "window.frames_added")
      assert frame["position"] == "fixed"
      assert frame["left"] == "-10000px"
      assert "%PDF-1.4\n" <> html = frame["text"]
      assert html =~ "<p>#{record.name} renamed</p>"
      conn
    end)
    # The dialog is modal, and focus coming back to the page is it closing:
    # the frame goes a moment later.
    |> tap(&read(&1, "window.dispatchEvent(new Event('focus'))"))
    |> refute_has("iframe")
  end
end
