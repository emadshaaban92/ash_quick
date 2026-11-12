defmodule AshQuick.LiveView.DownloadUtils do
  @moduledoc """
  Delivers a file an action produced itself, the way a print delivers its PDF:
  pushed over the LiveView socket to the tab that ran the action, which saves
  it. Nothing is stored and no link is handed out.

  The action marks the record it returns with `:ash_quick_download` in its
  metadata, from a change or the action's own code:

      Ash.Resource.put_metadata(record, :ash_quick_download, %{
        data: bytes,
        filename: "contract-watermarked.pdf",
        content_type: "application/pdf"
      })

    * `:data` — the file's raw bytes, a binary. AshQuick base64-encodes them
      for the socket.
    * `:filename` — the name the browser saves the file under, a non-empty
      string.
    * `:content_type` — the file's media type, a non-empty string.

  AshQuick never sets the mark. Only a QuickView reads it: run from a row or
  bulk action, the details page or an action form, a marked record's file is
  pushed after the action has committed. An action called from anywhere else
  (a seed, another action, a controller) just returns the record.

  A bulk run delivers one file per marked record, in the order the records
  came back. A mark that is not a map holding all three keys, a binary
  `:data` and non-empty string `:filename` and `:content_type`, is logged and
  flashed as recorded but not delivered; the other records' files still go.

  The file travels base64-encoded in one `"ash_quick:download"` event, so the
  whole of it is held in the LiveView process and crosses the socket at once.
  Keep such files to a size that is sensible to send that way. The event
  carries `data` (base64), `filename` and `content_type`, and
  `attachAshQuick`'s listener (`assets/js/download.js`) saves it as a blob of
  that type.
  """

  require Logger
  import Phoenix.LiveView, only: [push_event: 3, put_flash: 3]
  use Gettext, backend: AshQuick.Gettext

  @doc """
  Pushes the file each record of `result` carries — what an action returned:
  `{:ok, record}`, an `Ash.BulkResult` or what `AshPhoenix.Form.submit/2`
  returns. Anything else, and records with no mark, leave the socket as it
  was.
  """
  def deliver(socket, result) do
    {delivered, malformed} =
      result
      |> marks()
      |> Enum.split_with(fn {_resource, mark} -> valid?(mark) end)

    socket =
      Enum.reduce(delivered, socket, fn {_resource, mark}, socket ->
        push_event(socket, "ash_quick:download", %{
          data: Base.encode64(mark.data),
          filename: mark.filename,
          content_type: mark.content_type
        })
      end)

    case malformed do
      [] ->
        socket

      malformed ->
        Enum.each(malformed, fn {resource, mark} ->
          Logger.error(
            "a file #{inspect(resource)} marked for download could not be delivered after " <>
              "its action was recorded: #{describe(mark)}"
          )
        end)

        put_flash(
          socket,
          :error,
          gettext("It was recorded, but its file could not be delivered.")
        )
    end
  end

  # A bulk run that wrote nothing (every row stale) delivers nothing either.
  defp marks({:ok, %_{} = record}), do: marked([record])
  defp marks(%Ash.BulkResult{status: :success, records: [_ | _] = records}), do: marked(records)
  defp marks(_not_written), do: []

  defp marked(records) do
    for %resource{__metadata__: %{ash_quick_download: mark}} <- records, do: {resource, mark}
  end

  defp valid?(%{data: data, filename: filename, content_type: content_type}),
    do: is_binary(data) and filled?(filename) and filled?(content_type)

  defp valid?(_mark), do: false

  defp filled?(value), do: is_binary(value) and value != ""

  # What is wrong with the mark, never what it holds: the bytes are the file
  # and the names may be the record's.
  defp describe(%{} = mark) do
    keys = Enum.reject([:data, :filename, :content_type], &valid_key?(mark, &1))
    "missing or invalid #{Enum.map_join(keys, ", ", &inspect/1)}"
  end

  defp describe(_mark), do: "expected a map with :data, :filename and :content_type"

  defp valid_key?(mark, :data), do: is_binary(Map.get(mark, :data))
  defp valid_key?(mark, key), do: filled?(Map.get(mark, key))
end
