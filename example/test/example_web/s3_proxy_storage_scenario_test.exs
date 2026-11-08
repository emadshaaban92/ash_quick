defmodule ExampleWeb.S3ProxyStorageScenarioTest do
  @moduledoc """
  `AshQuick.Storage.S3.Proxy` end to end: a picked file comes over the socket
  and is written to the bucket, a page renders it from a link on the
  application's own origin, and the router's forward to
  `AshQuick.Storage.S3.Proxy.Plug` reads it back from the bucket. An export
  downloads through the same plug under its filename.

  The bucket is `Example.Test.S3Stub`, standing in for S3 at the HTTP layer.

  Synchronous: `:storage` is global, so swapping it would leak into every case
  running alongside.
  """
  use ExampleWeb.FeatureCase, async: false

  alias AshQuick.Storage.S3.Proxy
  alias Example.Catalog.Category
  alias Example.Test.S3Stub

  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]

  @upload "form[image]_upload"
  @jpeg File.read!("priv/static/favicon.ico")
  @bucket "ash-quick-example-proxied"
  @export_timeout 2_000

  setup do
    previous = Application.get_env(:ash_quick, :storage)
    Application.put_env(:ash_quick, :storage, Proxy)
    on_exit(fn -> Application.put_env(:ash_quick, :storage, previous) end)
  end

  test "an upload is written to the bucket and served from the application", ctx do
    %{conn: conn, admin: admin} = ctx
    code = unique("C")
    signed_in = log_in(conn, admin)

    {:ok, view, _html} = live(signed_in, ~p"/categories/create")

    pick(view, "tent.jpg")

    view
    |> form("#category-create", %{"form" => %{"code" => code, "name" => "Tents"}})
    |> render_submit()

    category = Ash.get!(Category, [code: code], authorize?: false)
    assert category.image.key =~ ~r{^private/categories/.+-tent\.jpg$}
    assert S3Stub.body("#{@bucket}/#{category.image.key}") == @jpeg

    {:ok, view, _html} = live(signed_in, ~p"/categories/#{category.id}")
    src = view |> element(~s([data-field="image"] img)) |> render() |> attribute("src")

    assert src =~ ~r{^/test/proxied_files/private/categories/.+-tent\.jpg\?token=}

    # The token is what opens it, not the session.
    served = get(build_conn(), src)
    assert served.status == 200
    assert served.resp_body == @jpeg
    assert get_resp_header(served, "content-disposition") == ["inline"]
    assert get_resp_header(served, "content-type") == ["image/jpeg"]

    ranged = build_conn() |> put_req_header("range", "bytes=0-3") |> get(src)
    assert ranged.status == 206
    assert ranged.resp_body == binary_part(@jpeg, 0, 4)

    [path | _query] = String.split(src, "?")
    assert get(build_conn(), path).status == 404

    # `Plug.Head` in the endpoint turns a `HEAD` into a `GET` before the
    # router; the plug still answers it without reading the object.
    object = "#{@bucket}/#{category.image.key}"
    reads = length(S3Stub.reads(object))
    head = Phoenix.ConnTest.dispatch(build_conn(), @endpoint, :head, src)

    assert head.status == 200
    assert head.resp_body == ""
    assert get_resp_header(head, "content-length") == ["#{byte_size(@jpeg)}"]
    assert length(S3Stub.reads(object)) == reads
  end

  test "an export downloads through the plug under its filename", ctx do
    %{conn: conn, admin: admin} = ctx
    tent = product(name: "Four-season tent", actor: admin)

    {:ok, view, _html} = live(log_in(conn, admin), ~p"/products?search=tent")

    view |> element("a", "CSV") |> render_click()
    render_async(view, @export_timeout)

    href =
      view |> element("#ash-quick-export-modal a", "Download") |> render() |> attribute("href")

    assert href =~ ~r{^/test/proxied_files/exports/.+\.csv\?token=}

    download = get(build_conn(), href)

    assert download.status == 200
    assert download.resp_body =~ tent.name
    assert [disposition] = get_resp_header(download, "content-disposition")
    assert disposition =~ ~r/^attachment; filename=".+\.csv"/
  end

  test "mix ash_quick.check finds the forward the storage builds its links under" do
    report = AshQuick.Check.run(router: ExampleWeb.Router, nav: nil, domains: [])
    refute Enum.any?(report.findings, &(&1.check in [:unserved_storage, :piped_storage]))
  end

  defp pick(view, filename) do
    view
    |> file_input("form[phx-submit=save]", @upload, [
      %{name: filename, content: @jpeg, type: "image/jpeg", size: byte_size(@jpeg)}
    ])
    |> render_upload(filename)
  end

  defp attribute(html, name) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute(name)
    |> List.first()
  end
end
