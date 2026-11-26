defmodule ExampleWeb.Browser.S3UploadTest do
  @moduledoc """
  The `S3` client uploader in a real browser: the colocated script
  `withAshQuick` hands LiveView as `uploaders.S3`. A file picked on a form is
  `PUT` straight to the URL `AshQuick.Storage.S3.upload_target/2` presigned,
  with the `Content-Type` the URL was signed for, and only a 2xx answer
  finishes the entry.

  No bucket answers here: the page's requests to the store
  (`Example.Uploads.ObjectStore`, whose arriving objects go under
  `quarantine/`) are answered by a Playwright route instead, which hands
  each request to the test. Playwright answers the CORS preflight itself.
  """
  use ExampleWeb.BrowserCase

  alias Example.Catalog.Category

  @bytes File.read!("priv/static/favicon.ico")

  setup do
    %{admin: admin} = roles()
    dir = Path.join(System.tmp_dir!(), unique("s3-upload-"))
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "tent.jpg")
    File.write!(path, @bytes)
    %{admin: admin, path: path}
  end

  # Answers every request to the store with `status`, and sends the test
  # each one.
  defp bucket(conn, status) do
    test = self()

    {:ok, _} =
      PlaywrightEx.BrowserContext.route(
        conn.context_id,
        "**/quarantine/**",
        fn route, request ->
          send(test, {:store, request.method, request})

          cors = %{"access-control-allow-origin" => "*"}
          {:ok, _} = PlaywrightEx.Route.fulfill(route, status: status, headers: cors, body: "")
        end,
        timeout: 5_000
      )

    conn
  end

  defp pick(conn, path) do
    {:ok, _} =
      PlaywrightEx.Frame.set_input_files(conn.frame_id,
        selector: ~s(input[name="form[image]_upload"]),
        local_paths: [path],
        timeout: 5_000
      )

    conn
  end

  defp open_create(conn, admin) do
    conn
    |> log_in(admin)
    |> visit(~p"/categories/create")
    |> connected()
  end

  test "puts the file to the presigned URL as the type it was signed for, then saves its key",
       %{conn: conn, admin: admin, path: path} do
    code = unique("C")

    conn
    |> open_create(admin)
    |> bucket(200)
    |> fill_in("Code", with: code)
    |> fill_in("Name", with: "Tents")
    |> pick(path)
    |> assert_has("[data-attachment-field=image] button[aria-label='Remove']")
    |> click("form button[type=submit]")
    |> assert_has("h1", text: "Tents")

    assert_received {:store, "PUT", put}
    uri = URI.parse(put.url)
    assert uri.host == "#{Example.Uploads.ObjectStore.bucket()}.s3.amazonaws.com"
    assert uri.query =~ "X-Amz-Signature="
    assert uri.query =~ "X-Amz-SignedHeaders=content-length%3Bcontent-type%3Bhost"
    # Playwright hands a route no body of a file's bytes, so the test reads
    # the header the signature binds. Chromium would send a `.jpg` as
    # `image/jpeg` by itself too, so this does not tell the uploader's
    # header from the browser's.
    assert %{name: "Content-Type", value: "image/jpeg"} in put.headers

    image = Ash.get!(Category, [code: code], authorize?: false).image
    assert image.original_filename == "tent.jpg"
    assert put.url =~ Path.basename(image.key)
  end

  test "an answer other than 2xx fails the entry, and the form says so",
       %{conn: conn, admin: admin, path: path} do
    conn
    |> open_create(admin)
    |> bucket(403)
    |> pick(path)
    |> assert_has("p.text-error", text: "External Client Failure")

    assert_received {:store, "PUT", _put}
  end
end
