defmodule Example.Test.PdfRendererDouble do
  @moduledoc """
  The `AshQuick.PdfRenderer` the test suite prints through, in place of a
  Chrome: its "PDF" is the template's HTML behind a PDF header, so a test reads
  what a print said off the `"ash_quick:pdf"` event it pushed.
  """
  @behaviour AshQuick.PdfRenderer

  @impl true
  def render(html) when is_binary(html), do: Base.encode64("%PDF-1.4\n" <> html)
  def render(sources) when is_list(sources), do: sources |> Enum.map_join(&html!/1) |> render()
  def render(source), do: source |> html!() |> render()

  @doc "What a pushed `\"ash_quick:pdf\"` event's PDF says."
  def printed_pdf(%{data: data}), do: Base.decode64!(data)

  # The page rescues whatever a render raises and says the PDF could not be
  # produced, so a source this double cannot read would pass for the
  # template's failure. The logged error says whose limit it was.
  defp html!(%{source: {:html, html}}), do: html

  defp html!(other) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} renders HTML only, as a string or `{:html, html}` " <>
            "sources, and was handed: #{inspect(other, limit: 5)}"
  end
end
