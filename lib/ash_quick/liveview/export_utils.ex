defmodule AshQuick.LiveView.ExportUtils do
  @moduledoc false
  alias AshQuick.Labels
  alias NimbleCSV.RFC4180, as: CSV
  alias AshQuick.LiveView.QuickView.Options

  alias AshQuick.LiveView.Utils

  @formula_triggers ["=", "+", "-", "@", "\t", "\r"]

  @doc """
  Writes the rows `query` reads to a file in `format`, stores it under
  `exports/<actor id>/` and answers `{:ok, download_url}`.

  Answers `{:error, {:too_many_rows, max}}`, having written nothing, when the
  query reads more rows than `AshQuick.Config.export_max_rows/0` allows.
  """
  def generate_export_url(query, actor, %Options{} = options, format, timezone)
      when format in [:xlsx, :csv] do
    case over_ceiling(query) do
      nil -> write_export(query, actor, options, format, timezone)
      max -> {:error, {:too_many_rows, max}}
    end
  end

  # One count ahead of the stream, so a table too large to export is refused
  # before a row of it is read rather than after a file of it is written.
  defp over_ceiling(query) do
    case AshQuick.Config.export_max_rows() do
      :infinity -> nil
      max -> if Ash.count!(query) > max, do: max
    end
  end

  @doc """
  A text cell as a spreadsheet reads as text.

  Opened from a CSV, a cell starting with `=`, `+`, `-`, `@`, a tab or a
  carriage return is run as a formula, so a record named `=HYPERLINK(...)`
  would be live in the export of whoever opened it. Such a cell is written
  behind a `'`, which a spreadsheet takes as "this is text". A cell that is
  wholly a number is left alone: `-5` is a value, not a formula.
  """
  def neutralize(<<first::binary-size(1), _rest::binary>> = text)
      when first in @formula_triggers do
    case Float.parse(text) do
      {_number, ""} -> text
      _not_a_number -> "'" <> text
    end
  end

  def neutralize(text), do: text

  # sobelow_skip ["Traversal.FileModule"]
  defp write_export(query, actor, %Options{} = options, :xlsx, timezone) do
    # An xlsx string cell is an inline string, which no spreadsheet evaluates,
    # so its text is written as it is.
    {header, body} = generate_stream_data(query, options, %{timezone: timezone, text: & &1})

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
  defp write_export(query, actor, %Options{} = options, :csv, timezone) do
    {header, body} =
      generate_stream_data(query, options, %{timezone: timezone, text: &neutralize/1})

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

  defp generate_stream_data(query, options, ctx) do
    # Keyset where the action offers it, offset where it pages by offset alone:
    # a list reads offset pages, so an action it lists is one it can export.
    # Never a full read, which would hold the whole table in memory. Offset
    # batches can repeat or skip a row that another writer moves meanwhile;
    # keyset batches cannot.
    #
    # Batches of up to 250 rows, held to the action's `max_page_size`, not
    # its `default_limit`: a batch is a read, and a count too on a countable
    # action, so batches of a page's 20 rows read a large table many times.
    rows =
      Ash.stream!(query, timeout: :infinity, allow_stream_with: :offset, batch_size: 250)

    header =
      options.export_fields
      |> Enum.map(&Labels.field/1)

    body =
      rows
      |> Stream.map(fn row ->
        options.export_fields
        |> Enum.map(&field_export_value(row, Utils.field_path(&1), ctx))
      end)

    {header, body}
  end

  defp field_export_value(nil, _path, _ctx) do
    ""
  end

  defp field_export_value(value, _path, _ctx) when is_number(value) do
    value
  end

  defp field_export_value(value, _path, ctx) when is_atom(value) do
    ctx.text.(Atom.to_string(value))
  end

  defp field_export_value(value, _path, ctx) when is_binary(value) do
    ctx.text.(value)
  end

  defp field_export_value(value, _path, _ctx) when is_non_struct_map(value) do
    Jason.encode!(value, pretty: true)
  end

  defp field_export_value(%DateTime{} = value, _path, ctx) do
    AshQuick.Config.format_datetime(value, ctx.timezone)
  end

  defp field_export_value(%Date{} = value, _path, _ctx) do
    AshQuick.Config.format_date(value)
  end

  defp field_export_value(%NaiveDateTime{} = value, _path, _ctx) do
    AshQuick.Config.format_datetime(value)
  end

  defp field_export_value(%Time{} = value, _path, ctx) do
    AshQuick.Config.format_time(value, format: :medium, timezone: ctx.timezone)
  end

  defp field_export_value(%{__struct__: Money} = value, _path, _ctx) do
    AshQuick.Config.format_money(value)
  end

  # Guarded once, as the cell it becomes: a spreadsheet reads a formula off a
  # cell's first character, so an entry further in needs no `'` of its own.
  defp field_export_value(value, path, ctx) when is_list(value) do
    value
    |> Enum.map_join(", ", &field_export_value(&1, path, %{ctx | text: fn text -> text end}))
    |> ctx.text.()
  end

  defp field_export_value(value, [path], ctx) do
    field_export_value(value, path, ctx)
  end

  # A `sensitive?` field is redacted in a file the way it is on the page. A
  # plain map has gone to JSON above, so a struct is all that reaches here.
  defp field_export_value(%resource{} = value, field_name, ctx) when is_atom(field_name) do
    case {AshQuick.Info.sensitive?(resource, field_name), Map.get(value, field_name)} do
      {true, nil} -> ""
      {true, field_value} -> AshQuick.Info.mask(field_value)
      {false, field_value} -> field_export_value(field_value, [], ctx)
    end
  end

  defp field_export_value(value, {relationship_name, rest}, ctx)
       when is_map(value) and is_atom(relationship_name) do
    field_export_value(Map.get(value, relationship_name), rest, ctx)
  end

  defp field_export_value(value, _path, ctx) do
    if String.Chars.impl_for(value) do
      ctx.text.(to_string(value))
    else
      ""
    end
  end
end
