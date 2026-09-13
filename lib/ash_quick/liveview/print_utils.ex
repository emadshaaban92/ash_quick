defmodule AshQuick.LiveView.PrintUtils do
  @moduledoc """
  Generates PDFs from selected records using ChromicPDF, uploads to S3,
  and returns a presigned download URL.

  Follows the same pattern as `AshQuick.LiveView.ExportUtils` for Excel/CSV exports.

  ## Print Templates

  A print template module must implement the `AshQuick.PrintTemplate` behaviour:

    - `label/0`     — human-readable name for the template
    - `load_opts/0`  — relationships/aggregates to load
    - `render/1`     — returns ChromicPDF source(s) for the given records

  ## Usage

  Called from `ListUtils` / `DetailsUtils` when the user triggers a print action:

      PrintUtils.generate_print_url(record_ids, actor, scope, template_module, resource)
  """

  require Ash.Query

  alias AshQuick.LiveView.Utils

  @doc """
  Loads records by IDs, renders them to a PDF, uploads to S3, and returns a presigned URL.
  """
  def generate_print_url(record_ids, actor, scope, template_module, resource) do
    load_opts = template_module.load_opts()

    records =
      resource
      |> Ash.Query.filter(id in ^record_ids)
      |> Ash.Query.load(load_opts)
      |> Utils.load_display_label()
      |> Ash.read!(scope: scope)

    {:ok, pdf_tmp_path} = Briefly.create(extname: ".pdf")

    case template_module.render(records) do
      html when is_binary(html) ->
        ChromicPDF.print_to_pdf({:html, html},
          output: pdf_tmp_path,
          print_to_pdf: %{preferCSSPageSize: true}
        )

      sources when is_list(sources) ->
        render_and_merge(sources, pdf_tmp_path)

      %{source: source, opts: opts} ->
        ChromicPDF.print_to_pdf(source, [{:output, pdf_tmp_path} | opts])
    end

    resource_name = Ash.Resource.Info.plural_name(resource)
    template_label = template_module.label() |> String.downcase() |> String.replace(" ", "_")

    date_part =
      AshQuick.Config.now_in_timezone()
      |> Calendar.strftime("%y-%m-%d-%H-%M-%S")

    count = length(records)

    filename =
      if count == 1 do
        record = hd(records)
        name = AshQuick.Info.display_value(record) || Map.get(record, :id)
        "#{name}_#{template_label}"
      else
        "#{resource_name}_#{template_label}_#{count}"
      end

    key = "prints/#{actor.id}/#{filename}-#{date_part}.pdf"

    :ok = AshQuick.Storage.upload(key, pdf_tmp_path, content_type: "application/pdf")

    {:ok, AshQuick.Storage.presigned_get_url(key, expires_in: 3600)}
  end

  # Renders each source individually with ChromicPDF (preserving native
  # headers/footers/page numbers), then merges using MergePdf (lopdf/Rust)
  # which does page-level concatenation without re-processing fonts.
  # This avoids Ghostscript's pdfwrite device which mangles font subsets.
  # sobelow_skip ["Traversal.FileModule"]
  defp render_and_merge(sources, output_path) do
    pdf_binaries =
      Enum.map(sources, fn
        %{source: source, opts: opts} ->
          {:ok, blob} = ChromicPDF.print_to_pdf(source, opts)
          Base.decode64!(blob)

        source ->
          {:ok, blob} = ChromicPDF.print_to_pdf(source)
          Base.decode64!(blob)
      end)

    {:ok, merged} = MergePdf.merge_binaries(pdf_binaries)
    File.write!(output_path, merged)
  end
end
