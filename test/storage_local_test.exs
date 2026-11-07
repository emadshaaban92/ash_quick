defmodule AshQuick.Storage.LocalTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias AshQuick.Storage.Local

  @secret String.duplicate("local-storage-secret-", 4)

  setup do
    root = Path.join(System.tmp_dir!(), "ash_quick_local_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    source = Path.join(root <> "-source", "upload")
    File.mkdir_p!(Path.dirname(source))
    on_exit(fn -> File.rm_rf!(Path.dirname(source)) end)

    %{opts: [root: root, secret_key_base: @secret, at: "/files"], root: root, source: source}
  end

  defp store(ctx, key, bytes) do
    File.write!(ctx.source, bytes)
    :ok = Local.put_file(key, ctx.source, ctx.opts)
  end

  # What the router hands the plug once `forward "/files"` has matched.
  defp get(url, opts) do
    %URI{path: "/files/" <> key, query: query} = URI.parse(url)
    conn = conn(:get, "/" <> key <> if(query, do: "?" <> query, else: ""))
    Local.Plug.call(conn, Local.Plug.init(opts))
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()

  describe "put_file/3" do
    test "writes the file under the root at its key", ctx do
      store(ctx, "private/products/a-tent.jpg", "tent")

      assert File.read!(Path.join(ctx.root, "private/products/a-tent.jpg")) == "tent"
      assert Path.wildcard(Path.join(ctx.root, "**/*.partial-*")) == []
    end

    test "refuses a key that could reach outside the root", ctx do
      File.write!(ctx.source, "x")

      for key <- ["../escape.jpg", "/etc/passwd", "a/../../b", "a//b", "./a", "a\\b", "a\0b", ""] do
        assert Local.put_file(key, ctx.source, ctx.opts) == {:error, :invalid_key}, key
      end

      refute File.exists?(Path.join(Path.dirname(ctx.root), "escape.jpg"))
    end

    test "refuses a key with a colon, which the plug could never serve", ctx do
      File.write!(ctx.source, "x")
      assert Local.put_file("public/x:y.png", ctx.source, ctx.opts) == {:error, :invalid_key}
    end

    test "keeps a name that only contains dots", ctx do
      store(ctx, "private/a..b.txt", "dots")
      assert File.read!(Path.join(ctx.root, "private/a..b.txt")) == "dots"
    end

    test "says so when the source is not there", ctx do
      assert {:error, :enoent} = Local.put_file("private/x.txt", "/no/such/file", ctx.opts)
    end
  end

  describe "url/2 and the plug" do
    test "a public object is served by its path, with no token", ctx do
      store(ctx, "public/logo.png", "png")

      url = Local.url("public/logo.png", [visibility: :public] ++ ctx.opts)
      assert url == "/files/public/logo.png"

      conn = get(url, ctx.opts)
      assert conn.status == 200
      assert conn.resp_body == "png"
      assert header(conn, "content-type") =~ "image/png"
      assert header(conn, "content-disposition") == "inline"
      assert header(conn, "x-content-type-options") == "nosniff"
      assert header(conn, "cache-control") == "public"
    end

    test "a private object is served only with its token", ctx do
      store(ctx, "private/scan.jpg", "jpg")

      url = Local.url("private/scan.jpg", [visibility: :private] ++ ctx.opts)
      assert url =~ ~r{^/files/private/scan\.jpg\?token=}

      assert %{status: 200, resp_body: "jpg"} = conn = get(url, ctx.opts)
      assert header(conn, "cache-control") == "private"

      assert get("/files/private/scan.jpg", ctx.opts).status == 404
      assert get("/files/private/scan.jpg?token=forged", ctx.opts).status == 404
    end

    test "a token opens only the key it was minted for", ctx do
      store(ctx, "private/mine.jpg", "mine")
      store(ctx, "private/theirs.jpg", "theirs")

      "/files/private/mine.jpg?" <> query =
        Local.url("private/mine.jpg", [visibility: :private] ++ ctx.opts)

      assert get("/files/private/theirs.jpg?" <> query, ctx.opts).status == 404
    end

    test "a token signed with another secret opens nothing", ctx do
      store(ctx, "private/scan.jpg", "jpg")
      other = Keyword.put(ctx.opts, :secret_key_base, String.duplicate("another-secret-", 5))

      assert get(Local.url("private/scan.jpg", other), ctx.opts).status == 404
    end

    test "a token stops working once it expires", ctx do
      store(ctx, "private/scan.jpg", "jpg")

      url = Local.url("private/scan.jpg", [expires_in: -1] ++ ctx.opts)
      assert get(url, ctx.opts).status == 404
    end

    test "a missing object is a 404, with or without a token", ctx do
      assert get(Local.url("private/gone.jpg", ctx.opts), ctx.opts).status == 404
      assert get("/files/public/gone.jpg", ctx.opts).status == 404
    end

    test "a path that could reach outside the root is a 404", ctx do
      File.write!(Path.join(Path.dirname(ctx.root), "outside.txt"), "secret")
      on_exit(fn -> File.rm(Path.join(Path.dirname(ctx.root), "outside.txt")) end)

      conn = conn(:get, "/public/../../outside.txt")
      assert Local.Plug.call(conn, ctx.opts).status == 404
    end

    test "keys are encoded per segment", ctx do
      store(ctx, "public/a b/ü.png", "png")

      url = Local.url("public/a b/ü.png", [visibility: :public] ++ ctx.opts)
      assert url == "/files/public/a%20b/%C3%BC.png"
      assert get(url, ctx.opts).resp_body == "png"
    end

    # `Plug.Static` decodes each segment it is handed, so a key holding a `%`
    # must reach it encoded, or it reads another file or raises.
    test "a key holding percent signs or spaces reads back as written", ctx do
      for key <- ["public/100%.png", "public/a%20b.png", "public/a b.png"] do
        store(ctx, key, key)
        url = Local.url(key, [visibility: :public] ++ ctx.opts)
        assert %{status: 200, resp_body: ^key} = get(url, ctx.opts), key
      end
    end

    # The token names the key as stored; the request path names it encoded.
    test "a private key holding a space or a percent sign opens with its token", ctx do
      for key <- ["private/a b.png", "private/100%.png"] do
        store(ctx, key, key)
        assert %{status: 200, resp_body: ^key} = get(Local.url(key, ctx.opts), ctx.opts), key
      end
    end

    test "an encoded traversal or a malformed escape is a 404", ctx do
      for path <- ["/public/..%2F..%2Foutside.txt", "/public/%2E%2E/x.txt", "/public/bad%zz.png"] do
        assert Local.Plug.call(conn(:get, path), ctx.opts).status == 404, path
      end
    end

    test "a public/ under another prefix needs a token", ctx do
      store(ctx, "quarantine/public/x.png", "png")
      assert get("/files/quarantine/public/x.png", ctx.opts).status == 404
    end

    test "only GET and HEAD are answered", ctx do
      store(ctx, "public/logo.png", "png")

      assert Local.Plug.call(conn(:head, "/public/logo.png"), ctx.opts).status == 200
      assert Local.Plug.call(conn(:put, "/public/logo.png"), ctx.opts).status == 404
      assert Local.Plug.call(conn(:delete, "/public/logo.png"), ctx.opts).status == 404
    end

    test "a range request is answered with the range", ctx do
      store(ctx, "public/clip.mp4", "0123456789")

      conn =
        conn(:get, "/public/clip.mp4")
        |> Plug.Conn.put_req_header("range", "bytes=2-4")
        |> Local.Plug.call(ctx.opts)

      assert conn.status == 206
      assert conn.resp_body == "234"
    end
  end

  describe "serving from the application's origin" do
    test "a document a browser would run is sent as an attachment, sandboxed", ctx do
      for key <- ["public/page.html", "public/drawing.svg", "public/feed.xml"] do
        store(ctx, key, "<script>alert(1)</script>")
        conn = get("/files/" <> key, ctx.opts)

        assert conn.status == 200
        assert header(conn, "content-disposition") =~ ~r/^attachment; filename="/
        assert header(conn, "content-security-policy") =~ "sandbox"
        assert header(conn, "x-content-type-options") == "nosniff"
      end
    end

    test "media, PDFs and plain text are shown inline", ctx do
      for key <- ["public/a.jpg", "public/a.webm", "public/a.mp3", "public/a.pdf", "public/a.txt"] do
        store(ctx, key, "bytes")
        assert header(get("/files/" <> key, ctx.opts), "content-disposition") == "inline", key
      end
    end

    test "a PDF is left out of the sandbox, which a PDF viewer refuses", ctx do
      store(ctx, "public/a.pdf", "%PDF")
      refute header(get("/files/public/a.pdf", ctx.opts), "content-security-policy") =~ "sandbox"
    end
  end

  describe "download_url/2" do
    test "downloads the object under the filename its token names", ctx do
      store(ctx, "private/exports/abc.csv", "a,b")

      url =
        Local.download_url("private/exports/abc.csv", [filename: "Ventes été.csv"] ++ ctx.opts)

      conn = get(url, ctx.opts)

      assert conn.status == 200
      assert conn.resp_body == "a,b"

      assert header(conn, "content-disposition") ==
               ~s(attachment; filename="Ventes _t_.csv"; filename*=UTF-8''Ventes%20%C3%A9t%C3%A9.csv)
    end
  end

  describe "use AshQuick.Storage.Local" do
    defmodule Wrapper do
      use AshQuick.Storage.Local

      @impl true
      def put_file(key, path, opts),
        do: AshQuick.Storage.Local.put_file("wrapped/" <> key, path, opts)
    end

    test "delegates the seam, overridably, and marks the module as backed by Local", ctx do
      assert Wrapper.url("public/x.png", [visibility: :public] ++ ctx.opts) ==
               "/files/public/x.png"

      File.write!(ctx.source, "w")
      :ok = Wrapper.put_file("public/x.png", ctx.source, ctx.opts)
      assert File.exists?(Path.join(ctx.root, "wrapped/public/x.png"))

      assert Local.backs?(Wrapper)
      assert Local.backs?(Local)
      refute Local.backs?(AshQuick.Storage.S3)
    end
  end

  describe "configuration" do
    test "an unconfigured root says what to set" do
      assert_raise ArgumentError, ~r/needs a :root/, fn ->
        Local.put_file("private/x.txt", "/dev/null", [])
      end
    end

    test "an unconfigured signer says what to set", ctx do
      assert_raise ArgumentError, ~r/needs an :endpoint/, fn ->
        Local.url("private/x.txt", Keyword.drop(ctx.opts, [:secret_key_base]))
      end
    end

    test ":at defaults to /ash_quick/files", ctx do
      assert Local.url("public/x.png", visibility: :public, root: ctx.root) ==
               "/ash_quick/files/public/x.png"
    end
  end
end
