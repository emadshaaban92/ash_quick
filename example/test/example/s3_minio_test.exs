defmodule Example.S3MinioTest do
  @moduledoc """
  `AshQuick.Storage.S3` and `AshQuick.Storage.S3.Proxy` against a real
  S3-compatible server, MinIO, rather than `Example.Test.S3Stub`: the signing,
  the key encoding, the multipart upload and the ranged reads are all checked
  by a server that refuses what S3 would refuse.

  Tagged `:minio` and left out of a plain `mix test`. To run it:

      MINIO_DOMAIN=localhost minio server /tmp/minio-data
      echo "127.0.0.1 ash-quick-minio.localhost" | sudo tee -a /etc/hosts
      mix test --only minio

  `MINIO_DOMAIN` is what makes MinIO answer virtual-hosted URLs
  (`bucket.localhost`), and the hosts entry is what makes that name resolve.
  `MINIO_ENDPOINT`, `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD` default to
  `http://localhost:9000` and MinIO's own `minioadmin`.

  Every request names the server in its `ex_aws:` overrides, so the global
  ExAws configuration (pointed at the stub) is left alone and the suite runs
  next to everything else.
  """
  use ExUnit.Case, async: true

  @moduletag :minio

  import Plug.Test

  alias AshQuick.Storage.S3
  alias AshQuick.Storage.S3.Proxy

  @bucket "ash-quick-minio"
  @secret String.duplicate("minio-proxy-secret-", 4)

  # The characters a filename brings into a key that each layer encodes its
  # own way: a space, `+` (which S3 once read as a space), parentheses, `&`,
  # `=`, `;`, `,`, `'`, `!`, `~`, `*`, `%` and a non-ASCII letter.
  @odd "a b+c (1) &=;,'!~*%25 ü.txt"

  setup_all do
    for style <- [:path, :virtual] do
      case @bucket |> ExAws.S3.put_bucket("us-east-1") |> ExAws.request(ex_aws(style)) do
        {:ok, _created} -> :ok
        {:error, {:http_error, 409, _exists}} -> :ok
      end
    end

    policy =
      JSON.encode!(%{
        "Version" => "2012-10-17",
        "Statement" => [
          %{
            "Effect" => "Allow",
            "Principal" => %{"AWS" => ["*"]},
            "Action" => ["s3:GetObject"],
            "Resource" => ["arn:aws:s3:::#{@bucket}/public/*"]
          }
        ]
      })

    {:ok, _set} = @bucket |> ExAws.S3.put_bucket_policy(policy) |> ExAws.request(ex_aws(:path))
    :ok
  end

  defp endpoint, do: URI.parse(System.get_env("MINIO_ENDPOINT", "http://localhost:9000"))

  defp ex_aws(style) do
    %URI{scheme: scheme, host: host, port: port} = endpoint()

    [
      http_client: ExAws.Request.Req,
      access_key_id: System.get_env("MINIO_ROOT_USER", "minioadmin"),
      secret_access_key: System.get_env("MINIO_ROOT_PASSWORD", "minioadmin"),
      region: "us-east-1",
      scheme: "#{scheme}://",
      host: host,
      port: port,
      virtual_host: style == :virtual,
      retries: [max_attempts: 1]
    ]
  end

  # `host: nil` over the app's `:s3_host`, so public URLs are built from the
  # ExAws endpoint, as they are when `:s3_host` is unset.
  defp opts(style), do: [bucket: @bucket, host: nil, ex_aws: ex_aws(style)]

  defp key(prefix, name), do: "#{prefix}/minio/#{System.unique_integer([:positive])}-#{name}"

  defp file(bytes) do
    path = Path.join(System.tmp_dir!(), "ash-quick-minio-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # What the bucket holds under `key`, read with the application's credentials.
  defp stored(key) do
    {:ok, %{body: body, headers: headers}} =
      @bucket |> ExAws.S3.get_object(key) |> ExAws.request(ex_aws(:path))

    {body, Map.new(headers)}
  end

  defp fetch(method, url, options \\ []),
    do: Req.request!([method: method, url: url, retry: false, decode_body: false] ++ options)

  for style <- [:path, :virtual] do
    describe "AshQuick.Storage.S3, #{style}-style URLs" do
      @describetag style: style

      test "put_file/3 stores the bytes under the key, with their type", %{style: style} do
        key = key("private", @odd)

        assert S3.put_file(key, file("hello"), [content_type: "text/plain"] ++ opts(style)) ==
                 :ok

        assert {"hello", %{"content-type" => "text/plain"}} = stored(key)
      end

      # Past the 5 MiB part size, so it goes up in several parts.
      test "put_file/3 uploads a large file in parts, intact", %{style: style} do
        key = key("private", "large.bin")
        bytes = :crypto.strong_rand_bytes(11 * 1024 * 1024 + 7)

        assert S3.put_file(key, file(bytes), opts(style)) == :ok
        assert {^bytes, %{"etag" => etag}} = stored(key)
        assert etag =~ ~r/-3"$/
      end

      test "a private URL reads the object, and stops reading it once it expires",
           %{style: style} do
        key = key("private", @odd)
        :ok = S3.put_file(key, file("secret"), opts(style))

        url = S3.url(key, [visibility: :private] ++ opts(style))
        assert url =~ "X-Amz-Signature="
        assert %{status: 200, body: "secret"} = fetch(:get, url)

        # The signature covers the key: another key under the same signature
        # is refused.
        assert %{status: 403} = fetch(:get, String.replace(url, "/minio/", "/minio2/"))

        short = S3.url(key, [visibility: :private, expires_in: 1] ++ opts(style))
        Process.sleep(2_000)
        assert %{status: 403} = fetch(:get, short)
      end

      test "a download URL has the bucket name the file", %{style: style} do
        key = key("private", "report.csv")
        :ok = S3.put_file(key, file("a,b\n"), opts(style))

        url = S3.download_url(key, [filename: "تقرير مارس.csv"] ++ opts(style))
        response = fetch(:get, url)

        assert response.status == 200
        assert response.body == "a,b\n"

        assert Req.Response.get_header(response, "content-disposition") ==
                 [AshQuick.Storage.attachment_disposition("تقرير مارس.csv")]
      end

      test "a public URL reads a public/ object with no signature, and only those",
           %{style: style} do
        key = key("public", @odd)
        :ok = S3.put_file(key, file("open"), opts(style))

        url = S3.url(key, [visibility: :public] ++ opts(style))
        refute url =~ "X-Amz"
        assert %{status: 200, body: "open"} = fetch(:get, url)

        private = key("private", "closed.txt")
        :ok = S3.put_file(private, file("closed"), opts(style))
        assert %{status: 403} = fetch(:get, S3.url(private, [visibility: :public] ++ opts(style)))
      end

      test "an upload target takes the PUT it was signed for", %{style: style} do
        key = key("private", @odd)

        {:external, "S3", meta} =
          S3.upload_target(key, [content_type: "image/png", content_length: 4] ++ opts(style))

        assert meta.content_type == "image/png"

        assert %{status: 200} =
                 fetch(:put, meta.url,
                   body: "\x89PNG",
                   headers: [content_type: meta.content_type]
                 )

        assert {"\x89PNG", %{"content-type" => "image/png"}} = stored(key)
      end

      # What makes the stored type and the size cap the server's: both are
      # signed as headers, so the bucket refuses a PUT that changes either.
      test "an upload target refuses another type or another size", %{style: style} do
        key = key("private", "picked.png")

        {:external, "S3", meta} =
          S3.upload_target(key, [content_type: "image/png", content_length: 4] ++ opts(style))

        assert %{status: 403} =
                 fetch(:put, meta.url, body: "\x89PNG", headers: [content_type: "text/html"])

        assert %{status: 403} =
                 fetch(:put, meta.url, body: "\x89PNGXX", headers: [content_type: "image/png"])

        assert %{status: refused} = fetch(:put, meta.url, body: "\x89PNG")
        assert refused in [400, 403]

        assert {:error, {:http_error, 404, _missing}} =
                 @bucket |> ExAws.S3.head_object(key) |> ExAws.request(ex_aws(:path))
      end

      test "a browser's CORS preflight for the upload is answered", %{style: style} do
        {:external, "S3", meta} =
          S3.upload_target(
            key("private", "preflight.png"),
            [content_type: "image/png", content_length: 4] ++ opts(style)
          )

        response =
          fetch(:options, meta.url,
            headers: [
              origin: "http://app.example.test",
              access_control_request_method: "PUT",
              access_control_request_headers: "content-type"
            ]
          )

        assert response.status in [200, 204]
        assert Req.Response.get_header(response, "access-control-allow-origin") != []
      end
    end
  end

  describe "AshQuick.Storage.S3.Proxy" do
    setup do
      %{opts: [secret_key_base: @secret, at: "/files"] ++ opts(:path)}
    end

    # What the router hands the plug once `forward "/files"` has matched.
    defp proxied(method \\ :get, url, opts, headers \\ []) do
      %URI{path: "/files/" <> key, query: query} = URI.parse(url)
      conn = conn(method, "/" <> key <> if(query, do: "?" <> query, else: ""))

      headers
      |> Enum.reduce(conn, fn {name, value}, conn ->
        Plug.Conn.put_req_header(conn, name, value)
      end)
      |> Proxy.Plug.call(Proxy.Plug.init(opts))
    end

    defp header(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()

    test "serves what put_file/3 stored, by a link on the application's origin", ctx do
      key = key("private", @odd)
      :ok = Proxy.put_file(key, file("through the app"), [content_type: "text/plain"] ++ ctx.opts)

      url = Proxy.url(key, ctx.opts)
      assert url =~ ~r{^/files/private/}

      conn = proxied(url, ctx.opts)
      assert conn.status == 200
      assert conn.resp_body == "through the app"
      assert header(conn, "content-length") == "15"
      assert header(conn, "etag") =~ ~r/^".+"$/
      assert header(conn, "last-modified")

      [path | _query] = String.split(url, "?")
      assert proxied(path, ctx.opts).status == 404
    end

    test "a public/ object is served by its path alone", ctx do
      key = key("public", @odd)
      :ok = Proxy.put_file(key, file("png"), ctx.opts)

      conn = proxied(Proxy.url(key, [visibility: :public] ++ ctx.opts), ctx.opts)
      assert conn.status == 200
      assert conn.resp_body == "png"
    end

    test "streams an object in chunks, and answers ranges and validators", ctx do
      key = key("private", "video.mp4")
      bytes = :crypto.strong_rand_bytes(10_000)
      :ok = Proxy.put_file(key, file(bytes), ctx.opts)

      opts = [chunk_size: 1_024] ++ ctx.opts
      url = Proxy.url(key, opts)

      whole = proxied(url, opts)
      assert whole.status == 200
      assert whole.resp_body == bytes

      ranged = proxied(:get, url, opts, [{"range", "bytes=1000-5999"}])
      assert ranged.status == 206
      assert ranged.resp_body == binary_part(bytes, 1000, 5000)
      assert header(ranged, "content-range") == "bytes 1000-5999/10000"

      suffix = proxied(:get, url, opts, [{"range", "bytes=-10"}])
      assert suffix.status == 206
      assert suffix.resp_body == binary_part(bytes, 9990, 10)

      etag = header(whole, "etag")
      assert proxied(:get, url, opts, [{"if-none-match", etag}]).status == 304

      head = proxied(:head, url, opts)
      assert head.status == 200
      assert head.resp_body == ""
      assert header(head, "content-length") == "10000"
    end

    test "a download link saves the object under its filename", ctx do
      key = key("private", "export.csv")
      :ok = Proxy.put_file(key, file("a,b\n"), ctx.opts)

      conn = proxied(Proxy.download_url(key, [filename: "تقرير.csv"] ++ ctx.opts), ctx.opts)
      assert conn.status == 200
      assert conn.resp_body == "a,b\n"

      assert header(conn, "content-disposition") ==
               AshQuick.Storage.attachment_disposition("تقرير.csv")
    end

    test "a key the bucket does not hold answers 404", ctx do
      url = Proxy.url(key("private", "missing.txt"), ctx.opts)
      assert proxied(url, ctx.opts).status == 404
    end

    test "credentials the bucket refuses answer 404, not the object", ctx do
      key = key("public", "refused.txt")
      :ok = Proxy.put_file(key, file("x"), ctx.opts)

      wrong = Keyword.update!(ctx.opts, :ex_aws, &Keyword.put(&1, :secret_access_key, "wrong"))
      assert proxied(Proxy.url(key, [visibility: :public] ++ wrong), wrong).status == 404
    end

    @tag capture_log: true
    test "a bucket that cannot be reached answers 502", ctx do
      down = Keyword.update!(ctx.opts, :ex_aws, &Keyword.put(&1, :port, 1))
      url = Proxy.url(key("public", "down.txt"), [visibility: :public] ++ down)
      assert proxied(url, down).status == 502
    end
  end
end
