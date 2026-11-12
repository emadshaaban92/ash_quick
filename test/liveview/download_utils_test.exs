defmodule AshQuick.LiveView.DownloadUtilsTest do
  @moduledoc """
  What `DownloadUtils.deliver/2` makes of each shape an action's result comes
  in, and of each mark it cannot deliver. The page-level scenarios are in the
  example app's `ExampleWeb.DownloadScenarioTest`.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias AshQuick.LiveView.DownloadUtils

  defmodule Record do
    @moduledoc false
    defstruct [:name, __metadata__: %{}]
  end

  @not_delivered "It was recorded, but its file could not be delivered."

  defp socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}},
      private: %{live_temp: %{}}
    }
  end

  defp record(name, mark \\ :none)
  defp record(name, :none), do: %Record{name: name}
  defp record(name, mark), do: %Record{name: name, __metadata__: %{ash_quick_download: mark}}

  defp mark(name) do
    %{data: <<0xFF, 0x00>> <> name, filename: "#{name}.bin", content_type: "application/zip"}
  end

  # Held newest first, and sent in the order they were pushed.
  defp pushed(socket), do: socket.private.live_temp |> Map.get(:push_events, []) |> Enum.reverse()

  test "pushes a marked record's file base64-encoded, under its name and type" do
    socket = DownloadUtils.deliver(socket(), {:ok, record("one", mark("one"))})

    assert pushed(socket) == [
             [
               "ash_quick:download",
               %{
                 data: Base.encode64(<<0xFF, 0x00>> <> "one"),
                 filename: "one.bin",
                 content_type: "application/zip"
               }
             ]
           ]
  end

  test "pushes one file per marked record of a bulk run, in the records' order" do
    result = %Ash.BulkResult{
      status: :success,
      records: [record("b", mark("b")), record("skipped"), record("a", mark("a"))]
    }

    assert socket() |> DownloadUtils.deliver(result) |> pushed() |> Enum.map(&hd(tl(&1)).filename) ==
             ["b.bin", "a.bin"]
  end

  test "pushes nothing for a result that wrote nothing or carries no mark" do
    for result <- [
          {:ok, record("plain")},
          {:error, :anything},
          :ok,
          %Ash.BulkResult{status: :error, records: [record("x", mark("x"))]},
          %Ash.BulkResult{status: :success, records: []},
          %Ash.BulkResult{status: :success, records: nil}
        ] do
      socket = DownloadUtils.deliver(socket(), result)
      assert pushed(socket) == []
      assert socket.assigns.flash == %{}
    end
  end

  test "flashes and logs a mark it cannot deliver, and still delivers the rest" do
    malformed = [
      "not a map",
      %{filename: "x.bin", content_type: "text/plain"},
      %{data: 42, filename: "x.bin", content_type: "text/plain"},
      %{data: "x", filename: "", content_type: "text/plain"},
      %{data: "x", filename: "x.bin", content_type: :pdf}
    ]

    for mark <- malformed do
      result = %Ash.BulkResult{
        status: :success,
        records: [record("bad", mark), record("good", mark("good"))]
      }

      log =
        capture_log(fn ->
          socket = DownloadUtils.deliver(socket(), result)
          assert [["ash_quick:download", %{filename: "good.bin"}]] = pushed(socket)
          assert socket.assigns.flash == %{"error" => @not_delivered}
        end)

      assert log =~ "#{inspect(Record)} marked for download could not be delivered"
      refute log =~ "x.bin"
    end
  end
end
