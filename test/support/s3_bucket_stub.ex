defmodule AshQuick.Test.S3BucketStub do
  @moduledoc """
  A bucket in ETS, standing in for S3 at the HTTP layer, so
  `AshQuick.Storage.S3.Proxy` is driven through ExAws as it would be against a
  real store.

  Handed to a request as `ex_aws: [http_client: AshQuick.Test.S3BucketStub]`,
  never configured globally, so nothing else in the suite talks to it. Objects
  are keyed by bucket and key, and each test names a bucket of its own, so the
  suite stays async. Every request is recorded under its bucket for
  `requests/1`.

  Answers what the proxy's plug sends: `HEAD` and ranged `GET` of an object.
  A bucket named with `fail/2` answers every request with the status given.
  """

  @behaviour ExAws.Request.HttpClient

  @table __MODULE__

  @doc "Starts the table. Called once from `test_helper.exs`."
  def start do
    :ets.new(@table, [:named_table, :public, :bag, write_concurrency: true])
    :ok
  end

  @doc "Puts `body` at `key` in `bucket`, as an earlier upload would have."
  def put(bucket, key, body) do
    :ets.match_delete(@table, {{:object, bucket, key}, :_})
    :ets.insert(@table, {{:object, bucket, key}, body})
    :ok
  end

  defp body(bucket, key) do
    case :ets.lookup(@table, {:object, bucket, key}) do
      [] -> nil
      [{_key, body}] -> body
    end
  end

  @doc "Every request made against `bucket`, oldest first, as `{method, key, headers}`."
  def requests(bucket) do
    @table
    |> :ets.lookup({:request, bucket})
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  @doc "Makes every request against `bucket` fail with `status`, `500` by default."
  def fail(bucket, status \\ 500), do: :ets.insert(@table, {{:failing, bucket}, status})

  @impl true
  def request(method, url, _body, headers, _http_opts) do
    uri = URI.parse(url)
    # Path-style, as ExAws builds a URL unless told `virtual_host: true`.
    [bucket | rest] = uri.path |> String.trim_leading("/") |> String.split("/")
    key = rest |> Enum.join("/") |> URI.decode()
    headers = Map.new(headers, fn {name, value} -> {String.downcase(name), value} end)

    :ets.insert(
      @table,
      {{:request, bucket}, {System.unique_integer([:monotonic]), {method, key, headers}}}
    )

    case :ets.lookup(@table, {:failing, bucket}) do
      [{_failing, status}] -> {:ok, %{status_code: status, headers: [], body: "<Error/>"}}
      [] -> respond(method, bucket, key, headers)
    end
  end

  defp respond(:head, bucket, key, _headers) do
    case body(bucket, key) do
      nil ->
        {:ok, %{status_code: 404, headers: [], body: ""}}

      bytes ->
        {:ok,
         %{
           status_code: 200,
           headers: [
             {"Content-Length", Integer.to_string(byte_size(bytes))},
             {"ETag", ~s("#{:erlang.phash2(bytes)}")},
             {"Last-Modified", "Wed, 21 Oct 2026 07:28:00 GMT"}
           ],
           body: ""
         }}
    end
  end

  defp respond(:get, bucket, key, headers) do
    case {body(bucket, key), headers["range"]} do
      {nil, _range} ->
        {:ok, %{status_code: 404, headers: [], body: ""}}

      {bytes, "bytes=" <> range} ->
        [first, last] = range |> String.split("-") |> Enum.map(&String.to_integer/1)
        last = min(last, byte_size(bytes) - 1)
        {:ok, %{status_code: 206, headers: [], body: binary_part(bytes, first, last - first + 1)}}

      {bytes, nil} ->
        {:ok, %{status_code: 200, headers: [], body: bytes}}
    end
  end
end
