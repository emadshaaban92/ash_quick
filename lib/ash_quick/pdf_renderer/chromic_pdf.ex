defmodule AshQuick.PdfRenderer.ChromicPDF do
  @moduledoc """
  The default `AshQuick.PdfRenderer`: renders with ChromicPDF, merging a list
  of sources with MergePdf.
  """
  @behaviour AshQuick.PdfRenderer

  # ChromicPDF hands back base64, which is what the event carries.
  @impl true
  def render(html) when is_binary(html) do
    {:ok, pdf} = ChromicPDF.print_to_pdf({:html, html}, print_to_pdf: %{preferCSSPageSize: true})
    pdf
  end

  def render(%{source: source, opts: opts}) do
    {:ok, pdf} = ChromicPDF.print_to_pdf(source, opts)
    pdf
  end

  # Each source rendered on its own keeps Chrome's headers, footers and page
  # numbers; MergePdf joins the pages without re-processing fonts, which
  # Ghostscript's pdfwrite mangles.
  def render(sources) when is_list(sources) do
    {:ok, merged} =
      sources
      |> Enum.map(&(&1 |> render() |> Base.decode64!()))
      |> MergePdf.merge_binaries()

    Base.encode64(merged)
  end
end
