defmodule Example.Test.PresignHelpers do
  @moduledoc """
  Reads the parts of a presigned `PUT` URL that decide whether its size cap
  and its type bind.

  A signed header is not readable from the URL — `Content-Length` and
  `Content-Type` live in the signature, not in the query string — so pinning
  one takes a re-sign: `signature_for/2` rebuilds the same request with
  header values of the caller's choosing and hands back the signature it
  produces. Equal signatures mean the URL was signed for those values; other
  values must produce a different signature, which is what makes such an
  assertion able to fail.
  """

  @doc "The `X-Amz-SignedHeaders` list, in canonical order."
  def signed_headers(url) do
    url |> query() |> Map.fetch!("X-Amz-SignedHeaders") |> String.split(";")
  end

  @doc "The signed query parameters, `X-Amz-*` included."
  def query(url), do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  def signature(url), do: url |> query() |> Map.fetch!("X-Amz-Signature")

  @doc """
  The signature the same `PUT` would carry had it been signed for
  `content_length` bytes of `content_type`. Every other input — key, expiry,
  instant, and the non-`X-Amz-` query parameters — is taken from `url`, so
  those headers are the only thing that differs.
  """
  def signature_for(url, content_length: content_length, content_type: content_type) do
    params = query(url)

    key =
      url
      |> URI.parse()
      |> Map.fetch!(:path)
      |> String.trim_leading("/")
      |> URI.decode()

    {:ok, resigned} =
      ExAws.S3.presigned_url(
        ExAws.Config.new(:s3),
        :put,
        Example.Uploads.ObjectStore.bucket(),
        key,
        virtual_host: true,
        expires_in: String.to_integer(params["X-Amz-Expires"]),
        start_datetime: amz_datetime(params["X-Amz-Date"]),
        query_params: Enum.reject(params, fn {name, _value} -> amz_param?(name) end),
        headers: [{"content-type", content_type}, {"content-length", to_string(content_length)}]
      )

    signature(resigned)
  end

  defp amz_param?("X-Amz-" <> _rest), do: true
  defp amz_param?(_name), do: false

  # "20260819T124411Z" — the instant the URL was signed at, which the signature
  # depends on and so has to be reproduced exactly.
  defp amz_datetime(
         <<y::binary-4, m::binary-2, d::binary-2, "T", h::binary-2, min::binary-2, s::binary-2,
           "Z">>
       ) do
    {{int(y), int(m), int(d)}, {int(h), int(min), int(s)}}
  end

  defp int(binary), do: String.to_integer(binary)
end
