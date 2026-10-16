defmodule AshQuick.PdfRenderer do
  @moduledoc """
  Turns what a print template's `render/1` returned into the PDF an action's
  print delivers, base64-encoded as it travels over the socket.

  `config :ash_quick, pdf_renderer: MyApp.PdfRenderer` replaces the default,
  `AshQuick.PdfRenderer.ChromicPDF`. A test suite with no Chrome to run uses
  one to see what a print says: a renderer handing back the template's HTML
  lets a test read it off the pushed event.

  A renderer raises when it cannot render: the action has already been
  recorded, and the page says its PDF could not be produced.
  """

  @doc "Renders a print template's output to a PDF, base64-encoded."
  @callback render(
              String.t()
              | %{source: term(), opts: keyword()}
              | [%{source: term(), opts: keyword()}]
            ) :: String.t()
end
