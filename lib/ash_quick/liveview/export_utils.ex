defmodule AshQuick.LiveView.ExportUtils do
  @moduledoc false
  alias NimbleCSV.RFC4180, as: CSV
  alias AshQuick.LiveView.QuickView.Options

  alias AshQuick.LiveView.Utils

  # sobelow_skip ["Traversal.FileModule"]
  def generate_export_url(query, actor, %Options{} = options, :xlsx) do
    {header, body} = generate_stream_data(query, options)

    resource_name = Ash.Resource.Info.plural_name(options.resource)

    xlsx_stream =
      Exceed.Workbook.new("Export")
      |> Exceed.Workbook.add_worksheet(Exceed.Worksheet.new(resource_name, header, body))
      |> Exceed.stream!()

    {:ok, xlsx_tmp_file_name} = Briefly.create(extname: ".xlsx")

    xlsx_stream
    |> Stream.into(File.stream!(xlsx_tmp_file_name, [:write]))
    |> Stream.run()

    date_part =
      AshQuick.Config.now_in_timezone()
      |> Calendar.strftime("%y-%m-%d-%H-%M-%S")

    key = "exports/#{actor.id}/#{resource_name}-#{date_part}.xlsx"

    :ok =
      AshQuick.Storage.upload(key, xlsx_tmp_file_name,
        content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      )

    {:ok, AshQuick.Storage.presigned_get_url(key, expires_in: 3600)}
  end

  # sobelow_skip ["Traversal.FileModule"]
  def generate_export_url(query, actor, %Options{} = options, :csv) do
    {header, body} = generate_stream_data(query, options)

    {:ok, csv_tmp_file_name} = Briefly.create(extname: ".csv")

    Stream.concat([header], body)
    |> CSV.dump_to_stream()
    |> Stream.into(File.stream!(csv_tmp_file_name, [:write, :utf8]))
    |> Stream.run()

    resource_name = Ash.Resource.Info.plural_name(options.resource)

    date_part =
      AshQuick.Config.now_in_timezone()
      |> Calendar.strftime("%y-%m-%d-%H-%M-%S")

    key = "exports/#{actor.id}/#{resource_name}-#{date_part}.csv"

    :ok = AshQuick.Storage.upload(key, csv_tmp_file_name, content_type: "text/csv")

    {:ok, AshQuick.Storage.presigned_get_url(key, expires_in: 3600)}
  end

  defp generate_stream_data(query, options) do
    rows = Ash.stream!(query, timeout: :infinity)

    header =
      options.export_fields
      |> Enum.map(&Utils.field_label/1)

    body =
      rows
      |> Stream.map(fn row ->
        options.export_fields
        |> Enum.map(&field_export_value(row, Utils.field_path(&1)))
      end)

    {header, body}
  end

  defp field_export_value(nil, _path) do
    ""
  end

  defp field_export_value(value, _path) when is_number(value) do
    value
  end

  defp field_export_value(value, _path) when is_atom(value) do
    Atom.to_string(value)
  end

  defp field_export_value(value, _path) when is_binary(value) do
    value
  end

  defp field_export_value(value, _path) when is_non_struct_map(value) do
    Jason.encode!(value, pretty: true)
  end

  defp field_export_value(%DateTime{} = value, _path) do
    AshQuick.Config.format_datetime(value)
  end

  defp field_export_value(%Date{} = value, _path) do
    AshQuick.Config.format_date(value)
  end

  defp field_export_value(value, path) when is_list(value) do
    Enum.map_join(value, ", ", &field_export_value(&1, path))
  end

  defp field_export_value(value, [path]) do
    field_export_value(value, path)
  end

  defp field_export_value(value, field_name) when is_map(value) and is_atom(field_name) do
    field_export_value(Map.get(value, field_name), [])
  end

  defp field_export_value(value, {relationship_name, rest})
       when is_map(value) and is_atom(relationship_name) do
    field_export_value(Map.get(value, relationship_name), rest)
  end

  defp field_export_value(value, _path) do
    if String.Chars.impl_for(value) do
      to_string(value)
    else
      ""
    end
  end
end
