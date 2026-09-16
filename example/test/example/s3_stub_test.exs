defmodule Example.Test.S3StubTest do
  @moduledoc """
  The stub assembles an object out of the parts a multipart upload sends it,
  which is logic the export tests rest on: an assertion about the bytes a reader
  would have downloaded is only as good as the reassembly behind it.

  Keys are unique per case, so these run alongside everything else writing to
  the same bucket.
  """
  use ExUnit.Case, async: true

  alias Example.Test.S3Stub

  @parts 100
  @part_bytes 4096

  test "concatenates the parts in order, whatever order they arrive in" do
    key = key("concat")

    for number <- [3, 1, 2], do: put_part(key, number, "part#{number}-")

    assert S3Stub.body(key) == "part1-part2-part3-"
  end

  # The property that holds without a lock, and the reason a part is its own row
  # rather than an entry in a list under the key. Read the list, prepend, write
  # it back — and two writers that read the same copy keep only one of their
  # parts, so the object comes back short with nothing reporting an error.
  #
  # `ExAws.S3.upload/4` is free to send parts concurrently, and does so as soon
  # as a file is larger than one chunk — which the exports here are not yet, so
  # this is the case that has to be provoked rather than waited for.
  #
  # Provoking it takes a barrier: released one at a time, the writers serialize
  # by luck and the same assertion passes against an implementation that drops
  # parts. Held until every one of them is ready, a read-modify-write loses at
  # least one every run. The parts are large for the same reason — the longer
  # the list being copied, the wider the window.
  test "keeps every part when they are written concurrently" do
    key = key("race")
    bodies = Map.new(1..@parts, &{&1, part_body(&1)})
    parent = self()

    writers =
      for number <- 1..@parts do
        spawn(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> :ok)
          put_part(key, number, bodies[number])
          send(parent, {:written, self()})
        end)
      end

    for pid <- writers, do: assert_receive({:ready, ^pid}, 5_000)
    for pid <- writers, do: send(pid, :go)
    for pid <- writers, do: assert_receive({:written, ^pid}, 5_000)

    assert S3Stub.body(key) == Enum.map_join(1..@parts, "", &bodies[&1])
  end

  test "a single-shot PUT replaces the object rather than adding to it" do
    key = key("replace")

    put_part(key, 1, "from the multipart upload")
    assert {:ok, %{status_code: 200}} = S3Stub.request(:put, url(key), "written whole", [], [])

    assert S3Stub.body(key) == "written whole"
  end

  test "a key nothing was written to has no body, and is not listed" do
    key = key("absent")

    assert S3Stub.body(key) == nil
    refute key in S3Stub.keys()
  end

  test "lists a key once however many parts it took" do
    key = key("listed")

    for number <- 1..3, do: put_part(key, number, "#{number}")

    assert Enum.count(S3Stub.keys(), &(&1 == key)) == 1
  end

  defp put_part(key, number, body) do
    S3Stub.request(
      :put,
      "#{url(key)}?partNumber=#{number}&uploadId=#{key}",
      body,
      [],
      []
    )
  end

  defp url(key), do: "https://example-bucket.s3.amazonaws.com/#{key}"

  # Numbered, so the assertion is about the order the parts were reassembled in
  # as well as about all of them being there.
  defp part_body(number) do
    String.pad_leading("#{number}", 8, "0") <> String.duplicate("x", @part_bytes - 8)
  end

  defp key(prefix), do: "#{prefix}/#{System.unique_integer([:positive])}"
end
