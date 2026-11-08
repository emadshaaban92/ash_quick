defmodule AshQuick.Storage.S3.ProxyTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias AshQuick.Storage.S3.Proxy
  alias AshQuick.Test.S3BucketStub

  @secret String.duplicate("proxy-storage-secret-", 4)

  # `put_file/3` writes through `AshQuick.Storage.S3.put_file/3`, a multipart
  # upload whose answers need an XML parser the library does not depend on;
  # the example app drives it end to end.
  setup do
    bucket = "proxy-#{System.unique_integer([:positive])}"

    opts = [
      bucket: bucket,
      secret_key_base: @secret,
      at: "/files",
      ex_aws: [http_client: S3BucketStub, retries: [max_attempts: 1]]
    ]

    %{opts: opts, bucket: bucket}
  end

  defp store(ctx, key, bytes), do: S3BucketStub.put(ctx.bucket, key, bytes)

  # What the router hands the plug once `forward "/files"` has matched.
  defp get(url, opts, headers \\ []) do
    %URI{path: "/files/" <> key, query: query} = URI.parse(url)
    conn = conn(:get, "/" <> key <> if(query, do: "?" <> query, else: ""))

    headers
    |> Enum.reduce(conn, fn {name, value}, conn -> Plug.Conn.put_req_header(conn, name, value) end)
    |> Proxy.Plug.call(Proxy.Plug.init(opts))
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()

  defp gets(bucket) do
    for {:get, _key, headers} <- S3BucketStub.requests(bucket), do: headers["range"]
  end

  test "has no upload target, so browser uploads come over the socket" do
    refute function_exported?(Proxy, :upload_target, 2)
  end

  test "put_file/3 refuses a key the plug would refuse to serve", ctx do
    for key <- [
          "public/../private/x.pdf",
          "a//b",
          "./a",
          "a\\b",
          "a\0b",
          "",
          "public/x?acl",
          "a#b"
        ] do
      assert Proxy.put_file(key, "/no/such/file", ctx.opts) == {:error, :invalid_key}, key
    end

    assert S3BucketStub.requests(ctx.bucket) == []
  end

  describe "url/2 and the plug" do
    test "a public object is served by its path, with no token", ctx do
      store(ctx, "public/logo.png", "png")

      url = Proxy.url("public/logo.png", [visibility: :public] ++ ctx.opts)
      assert url == "/files/public/logo.png"

      conn = get(url, ctx.opts)
      assert conn.status == 200
      assert conn.resp_body == "png"
      assert header(conn, "content-type") =~ "image/png"
      assert header(conn, "content-length") == "3"
      assert header(conn, "content-disposition") == "inline"
      assert header(conn, "x-content-type-options") == "nosniff"
      assert header(conn, "cache-control") == "public"
      assert header(conn, "accept-ranges") == "bytes"
    end

    test "a private object is served only with its token", ctx do
      store(ctx, "private/scan.jpg", "jpg")

      url = Proxy.url("private/scan.jpg", [visibility: :private] ++ ctx.opts)
      assert url =~ ~r{^/files/private/scan\.jpg\?token=}

      assert %{status: 200, resp_body: "jpg"} = conn = get(url, ctx.opts)
      assert header(conn, "cache-control") == "private"

      assert get("/files/private/scan.jpg", ctx.opts).status == 404
      assert get("/files/private/scan.jpg?token=forged", ctx.opts).status == 404
    end

    test "a refused link never reaches the bucket", ctx do
      store(ctx, "private/scan.jpg", "jpg")
      assert get("/files/private/scan.jpg", ctx.opts).status == 404
      assert S3BucketStub.requests(ctx.bucket) == []
    end

    test "a token opens only the key it was minted for", ctx do
      store(ctx, "private/mine.jpg", "mine")
      store(ctx, "private/theirs.jpg", "theirs")

      "/files/private/mine.jpg?" <> query =
        Proxy.url("private/mine.jpg", [visibility: :private] ++ ctx.opts)

      assert get("/files/private/theirs.jpg?" <> query, ctx.opts).status == 404
    end

    test "a token stops working once it expires", ctx do
      store(ctx, "private/scan.jpg", "jpg")

      assert get(Proxy.url("private/scan.jpg", [expires_in: -1] ++ ctx.opts), ctx.opts).status ==
               404
    end

    test "a key the bucket does not hold is a 404", ctx do
      assert get(Proxy.url("private/gone.jpg", ctx.opts), ctx.opts).status == 404
      assert get("/files/public/gone.jpg", ctx.opts).status == 404
    end

    test "a bucket it cannot read is a 502", ctx do
      S3BucketStub.fail(ctx.bucket)

      {conn, log} =
        ExUnit.CaptureLog.with_log(fn -> get("/files/public/logo.png", ctx.opts) end)

      assert conn.status == 502
      assert log =~ "could not read \"public/logo.png\""
    end

    test "keys are encoded per segment and read back as written", ctx do
      for key <- ["public/a b/ü.png", "public/100%.png", "private/a b.png"] do
        store(ctx, key, key)
        url = Proxy.url(key, [visibility: vis(key)] ++ ctx.opts)
        assert %{status: 200, resp_body: ^key} = get(url, ctx.opts), key
      end

      assert Proxy.url("public/a b/ü.png", [visibility: :public] ++ ctx.opts) ==
               "/files/public/a%20b/%C3%BC.png"
    end

    test "a public/ prefix with a dot segment opens no private object", ctx do
      store(ctx, "exports/7/products.csv", "secret")
      store(ctx, "private/secret.pdf", "secret")

      for path <- [
            "/public/%2E%2E/exports/7/products.csv",
            "/public/../exports/7/products.csv",
            "/public//../private/secret.pdf",
            "/public/./../private/secret.pdf",
            "/public/..%2Fprivate%2Fsecret.pdf",
            "/public/%2e%2e%5Cprivate/secret.pdf",
            "/public/a%00/secret.pdf"
          ] do
        assert Proxy.Plug.call(conn(:get, path), ctx.opts).status == 404, path
      end

      assert S3BucketStub.requests(ctx.bucket) == []
    end

    test "a ? or # in a requested key never reaches the bucket as a query", ctx do
      store(ctx, "public/logo.png", "png")

      for path <- [
            "/public/logo.png%3FversionId%3Dold",
            "/public/logo.png%3Facl",
            "/public/logo.png%23x"
          ] do
        assert Proxy.Plug.call(conn(:get, path), ctx.opts).status == 404, path
      end

      assert S3BucketStub.requests(ctx.bucket) == []
    end

    test "a 403 from the bucket is a 404", ctx do
      S3BucketStub.fail(ctx.bucket, 403)
      assert get("/files/public/logo.png", ctx.opts).status == 404
    end

    test "a malformed escape is a 404", ctx do
      assert Proxy.Plug.call(conn(:get, "/public/bad%zz.png"), ctx.opts).status == 404
    end

    test "a public/ under another prefix needs a token", ctx do
      store(ctx, "quarantine/public/x.png", "png")
      assert get("/files/quarantine/public/x.png", ctx.opts).status == 404
    end

    test "only GET and HEAD are answered", ctx do
      store(ctx, "public/logo.png", "png")

      head = Proxy.Plug.call(conn(:head, "/public/logo.png"), ctx.opts)
      assert head.status == 200
      assert header(head, "content-length") == "3"
      assert head.resp_body == ""
      refute Enum.any?(S3BucketStub.requests(ctx.bucket), &match?({:get, _, _}, &1))

      assert Proxy.Plug.call(conn(:put, "/public/logo.png"), ctx.opts).status == 404
      assert Proxy.Plug.call(conn(:delete, "/public/logo.png"), ctx.opts).status == 404
    end

    test "a HEAD that Plug.Head turned into a GET reads no body", ctx do
      store(ctx, "public/logo.png", "png")

      conn =
        conn(:head, "/public/logo.png")
        |> Plug.Head.call([])
        |> Proxy.Plug.call(ctx.opts)

      assert conn.status == 200
      assert header(conn, "content-length") == "3"
      assert gets(ctx.bucket) == []
    end

    test "an empty object is served empty", ctx do
      store(ctx, "public/empty.txt", "")
      conn = get("/files/public/empty.txt", ctx.opts)
      assert conn.status == 200
      assert conn.resp_body == ""
      assert header(conn, "content-length") == "0"
    end
  end

  describe "streaming" do
    test "the object is read in chunks of :chunk_size", ctx do
      store(ctx, "public/clip.mp4", "0123456789")

      conn = get("/files/public/clip.mp4", [chunk_size: 4] ++ ctx.opts)

      assert conn.status == 200
      assert conn.resp_body == "0123456789"
      assert header(conn, "content-length") == "10"
      assert gets(ctx.bucket) == ["bytes=0-3", "bytes=4-7", "bytes=8-9"]
    end

    test "every chunk is pinned to the ETag the HEAD answered", ctx do
      store(ctx, "public/clip.mp4", "0123456789")
      etag = header(get("/files/public/clip.mp4", ctx.opts), "etag")

      pins =
        for {:get, _key, headers} <- S3BucketStub.requests(ctx.bucket), do: headers["if-match"]

      assert pins == [etag]
    end

    test "a single range is answered with that range", ctx do
      store(ctx, "public/clip.mp4", "0123456789")

      for {range, body, content_range} <- [
            {"bytes=2-4", "234", "bytes 2-4/10"},
            {"bytes=7-", "789", "bytes 7-9/10"},
            {"bytes=-2", "89", "bytes 8-9/10"},
            {"bytes=8-100", "89", "bytes 8-9/10"}
          ] do
        conn = get("/files/public/clip.mp4", ctx.opts, [{"range", range}])

        assert conn.status == 206, range
        assert conn.resp_body == body, range
        assert header(conn, "content-range") == content_range, range
        assert header(conn, "content-length") == Integer.to_string(byte_size(body)), range
      end
    end

    test "a range is honoured only under an if-range naming the object's ETag", ctx do
      store(ctx, "public/clip.mp4", "0123456789")
      etag = header(get("/files/public/clip.mp4", ctx.opts), "etag")

      current =
        get("/files/public/clip.mp4", ctx.opts, [{"range", "bytes=2-4"}, {"if-range", etag}])

      assert current.status == 206
      assert current.resp_body == "234"

      for stale <- [~s("other"), "Wed, 21 Oct 2026 07:28:00 GMT"] do
        conn =
          get("/files/public/clip.mp4", ctx.opts, [{"range", "bytes=2-4"}, {"if-range", stale}])

        assert conn.status == 200, stale
        assert conn.resp_body == "0123456789", stale
      end
    end

    test "a range past the end is unsatisfiable", ctx do
      store(ctx, "public/clip.mp4", "0123456789")
      conn = get("/files/public/clip.mp4", ctx.opts, [{"range", "bytes=10-"}])

      assert conn.status == 416
      assert header(conn, "content-range") == "bytes */10"
    end

    test "several ranges, or one it cannot read, get the whole object", ctx do
      store(ctx, "public/clip.mp4", "0123456789")

      for range <- ["bytes=0-1,4-5", "bytes=5-2", "bytes=x-", "items=0-1", "bytes=0-9"] do
        conn = get("/files/public/clip.mp4", ctx.opts, [{"range", range}])
        assert conn.status == 200, range
        assert conn.resp_body == "0123456789", range
      end
    end

    test "the bucket's validators are passed on, and a matching if-none-match is a 304", ctx do
      store(ctx, "public/logo.png", "png")

      conn = get("/files/public/logo.png", ctx.opts)
      etag = header(conn, "etag")
      assert etag
      assert header(conn, "last-modified") == "Wed, 21 Oct 2026 07:28:00 GMT"

      revalidated = get("/files/public/logo.png", ctx.opts, [{"if-none-match", etag}])
      assert revalidated.status == 304
      assert revalidated.resp_body == ""

      assert get("/files/public/logo.png", ctx.opts, [{"if-none-match", ~s("other")}]).status ==
               200
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
  end

  describe "download_url/2" do
    test "downloads the object under the filename its token names", ctx do
      store(ctx, "private/exports/abc.csv", "a,b")

      url =
        Proxy.download_url("private/exports/abc.csv", [filename: "Ventes été.csv"] ++ ctx.opts)

      conn = get(url, ctx.opts)

      assert conn.status == 200
      assert conn.resp_body == "a,b"

      assert header(conn, "content-disposition") ==
               ~s(attachment; filename="Ventes _t_.csv"; filename*=UTF-8''Ventes%20%C3%A9t%C3%A9.csv)
    end
  end

  describe "use AshQuick.Storage.S3.Proxy" do
    defmodule Wrapper do
      use AshQuick.Storage.S3.Proxy

      @impl true
      def url(key, opts), do: AshQuick.Storage.S3.Proxy.url("wrapped/" <> key, opts)
    end

    test "delegates the seam, overridably, and marks the module as backed by the proxy", ctx do
      assert Wrapper.url("public/x.png", [visibility: :public] ++ ctx.opts) ==
               "/files/wrapped/public/x.png"

      assert Wrapper.download_url("private/x.csv", [filename: "x.csv"] ++ ctx.opts) =~
               ~r{^/files/private/x\.csv\?token=}

      assert Proxy.backs?(Wrapper)
      assert Proxy.backs?(Proxy)
      refute Proxy.backs?(AshQuick.Storage.S3)
      refute Proxy.backs?(AshQuick.Storage.Local)
      refute AshQuick.Storage.Local.backs?(Wrapper)
    end
  end

  describe "configuration" do
    test "the bucket falls back to :s3_bucket" do
      assert Proxy.bucket([]) == AshQuick.Config.s3_bucket()
    end

    test "an unconfigured secret says what to set" do
      assert_raise ArgumentError, ~r/AshQuick.Storage.S3.Proxy needs an :endpoint/, fn ->
        Proxy.url("private/x.png", [])
      end
    end
  end

  defp vis("public/" <> _), do: :public
  defp vis(_key), do: :private
end

defmodule AshQuick.Storage.S3.ProxyLogTest do
  # Raises the global Logger level to catch a debug line, so the case runs
  # alone.
  use ExUnit.Case, async: false

  import Plug.Test

  alias AshQuick.Storage.S3.Proxy
  alias AshQuick.Test.S3BucketStub

  setup do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)
  end

  test "a 403 from the bucket is logged, since wrong credentials answer it too" do
    bucket = "proxy-log-#{System.unique_integer([:positive])}"
    S3BucketStub.fail(bucket, 403)

    opts = [
      bucket: bucket,
      secret_key_base: String.duplicate("proxy-storage-secret-", 4),
      ex_aws: [http_client: S3BucketStub, retries: [max_attempts: 1]]
    ]

    {conn, log} =
      ExUnit.CaptureLog.with_log([level: :debug], fn ->
        Proxy.Plug.call(conn(:get, "/public/logo.png"), opts)
      end)

    assert conn.status == 404
    assert log =~ ~s(was refused "public/logo.png")
  end
end
