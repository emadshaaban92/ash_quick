defmodule ExampleWeb.LocalStorageScenarioTest do
  @moduledoc """
  `AshQuick.Storage.Local` end to end: a picked file comes over the socket and
  lands under its `:root`, a page renders it from a link the router's forward
  to `AshQuick.Storage.Local.Plug` serves, and an export downloads through the
  same plug under its filename.

  Synchronous: `:storage` is global, so swapping it would leak into every case
  running alongside.
  """
  use ExampleWeb.FeatureCase, async: false

  alias AshQuick.Storage.Local
  alias Example.Catalog.Category

  import Plug.Conn, only: [get_resp_header: 2]

  @upload "form[image]_upload"
  @jpeg File.read!("priv/static/favicon.ico")
  @export_timeout 2_000

  setup do
    previous = Application.get_env(:ash_quick, :storage)
    Application.put_env(:ash_quick, :storage, Local)
    on_exit(fn -> Application.put_env(:ash_quick, :storage, previous) end)
  end

  test "an upload is written under the root and rendered from a signed link", ctx do
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

    {:ok, file} = Local.file_path(category.image.key)
    assert File.read!(file) == @jpeg

    {:ok, view, _html} = live(signed_in, ~p"/categories/#{category.id}")
    src = view |> element(~s([data-field="image"] img)) |> render() |> attribute("src")

    assert src =~ ~r{^/test/files/private/categories/.+-tent\.jpg\?token=}

    # The token is what opens it, not the session: the link works for whoever
    # holds it until it expires, as a presigned URL does.
    served = get(build_conn(), src)
    assert served.status == 200
    assert served.resp_body == @jpeg
    assert get_resp_header(served, "content-disposition") == ["inline"]

    [path | _query] = String.split(src, "?")
    assert get(build_conn(), path).status == 404
  end

  test "an export downloads through the plug under its filename", ctx do
    %{conn: conn, admin: admin} = ctx
    tent = product(name: "Four-season tent", actor: admin)

    {:ok, view, _html} = live(log_in(conn, admin), ~p"/products?search=tent")

    view |> element("a", "CSV") |> render_click()
    render_async(view, @export_timeout)

    href =
      view |> element("#ash-quick-export-modal a", "Download") |> render() |> attribute("href")

    assert href =~ ~r{^/test/files/exports/.+\.csv\?token=}

    download = get(build_conn(), href)

    assert download.status == 200
    assert download.resp_body =~ tent.name
    assert [disposition] = get_resp_header(download, "content-disposition")
    assert disposition =~ ~r/^attachment; filename=".+\.csv"/
  end

  test "mix ash_quick.check finds the forward the storage builds its links under" do
    report = AshQuick.Check.run(router: ExampleWeb.Router, nav: nil, domains: [])
    refute Enum.any?(report.findings, &(&1.check == :unserved_storage))
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
