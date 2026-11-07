defmodule AshQuick.LiveView.ExportUtils do
  @moduledoc false
  alias AshQuick.Labels
  alias NimbleCSV.RFC4180, as: CSV
  alias AshQuick.LiveView.QuickView.Options

  alias AshQuick.LiveView.Utils

  # sobelow_skip ["Traversal.FileModule"]
  def generate_export_url(query, actor, %Options{} = options, :xlsx, timezone) do
    {header, body} = generate_stream_data(query, options, timezone)

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
      AshQuick.Config.now_in_timezone(timezone)
      |> Calendar.strftime("%y-%m-%d-%H-%M-%S")

    filename = "#{resource_name}-#{date_part}.xlsx"
    key = "exports/#{actor.id}/#{filename}"

    :ok =
      AshQuick.Storage.put_file(key, xlsx_tmp_file_name,
        content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      )

    {:ok, AshQuick.Storage.download_url(key, filename: filename, expires_in: 3600)}
  end

  # sobelow_skip ["Traversal.FileModule"]
  def generate_export_url(query, actor, %Options{} = options, :csv, timezone) do
    {header, body} = generate_stream_data(query, options, timezone)

    {:ok, csv_tmp_file_name} = Briefly.create(extname: ".csv")

    Stream.concat([header], body)
    |> CSV.dump_to_stream()
    |> Stream.into(File.stream!(csv_tmp_file_name, [:write, :utf8]))
    |> Stream.run()

    resource_name = Ash.Resource.Info.plural_name(options.resource)

    date_part =
      AshQuick.Config.now_in_timezone(timezone)
      |> Calendar.strftime("%y-%m-%d-%H-%M-%S")

    filename = "#{resource_name}-#{date_part}.csv"
    key = "exports/#{actor.id}/#{filename}"

    :ok = AshQuick.Storage.put_file(key, csv_tmp_file_name, content_type: "text/csv")

    {:ok, AshQuick.Storage.download_url(key, filename: filename, expires_in: 3600)}
  end

  defp generate_stream_data(query, options, timezone) do
    rows = Ash.stream!(query, timeout: :infinity)

    header =
      options.export_fields
      |> Enum.map(&Labels.field/1)

    body =
      rows
      |> Stream.map(fn row ->
        options.export_fields
        |> Enum.map(&field_export_value(row, Utils.field_path(&1), timezone))
      end)

    {header, body}
  end

  defp field_export_value(nil, _path, _timezone) do
    ""
  end

  defp field_export_value(value, _path, _timezone) when is_number(value) do
    value
  end

  defp field_export_value(value, _path, _timezone) when is_atom(value) do
    Atom.to_string(value)
  end

  defp field_export_value(value, _path, _timezone) when is_binary(value) do
    value
  end

  defp field_export_value(value, _path, _timezone) when is_non_struct_map(value) do
    Jason.encode!(value, pretty: true)
  end

  defp field_export_value(%DateTime{} = value, _path, timezone) do
    AshQuick.Config.format_datetime(value, timezone)
  end

  defp field_export_value(%Date{} = value, _path, _timezone) do
    AshQuick.Config.format_date(value)
  end

  defp field_export_value(%NaiveDateTime{} = value, _path, _timezone) do
    AshQuick.Config.format_datetime(value)
  end

  defp field_export_value(%Time{} = value, _path, timezone) do
    AshQuick.Config.format_time(value, format: :medium, timezone: timezone)
  end

  defp field_export_value(%{__struct__: Money} = value, _path, _timezone) do
    AshQuick.Config.format_money(value)
  end

  defp field_export_value(value, path, timezone) when is_list(value) do
    Enum.map_join(value, ", ", &field_export_value(&1, path, timezone))
  end

  defp field_export_value(value, [path], timezone) do
    field_export_value(value, path, timezone)
  end

  # A `sensitive?` field is redacted in a file the way it is on the page. A
  # plain map has gone to JSON above, so a struct is all that reaches here.
  defp field_export_value(%resource{} = value, field_name, timezone) when is_atom(field_name) do
    case {AshQuick.Info.sensitive?(resource, field_name), Map.get(value, field_name)} do
      {true, nil} -> ""
      {true, field_value} -> AshQuick.Info.mask(field_value)
      {false, field_value} -> field_export_value(field_value, [], timezone)
    end
  end

  defp field_export_value(value, {relationship_name, rest}, timezone)
       when is_map(value) and is_atom(relationship_name) do
    field_export_value(Map.get(value, relationship_name), rest, timezone)
  end

  defp field_export_value(value, _path, _timezone) do
    if String.Chars.impl_for(value) do
      to_string(value)
    else
      ""
    end
  end
end
