defmodule AshQuick.PrintTemplate do
  @moduledoc """
  Behaviour for PDF print templates.

  Each module implementing this behaviour represents a single print template
  for a given Ash resource. The module provides everything needed to load
  the right data and render it as a PDF via ChromicPDF.

  ## Example

  The simplest approach is to return an HTML string. ChromicPDF will render
  it directly with `preferCSSPageSize: true`, so use `@page` CSS to control
  the page size. Use `break-after: page` for multi-page documents.

      defmodule MyApp.PDF.ItemLabelTemplate do
        @behaviour AshQuick.PrintTemplate

        @impl true
        def label, do: "Item Labels"

        @impl true
        def load_opts, do: [:product, :seller]

        @impl true
        def render(records) do
          pages = Enum.map(records, &page_html/1) |> Enum.join("\\n")

          \"""
          <html>
          <head>
            <style>
              @page { margin: 0; size: A4; }
              .page { break-after: page; }
              .page:last-child { break-after: auto; }
            </style>
          </head>
          <body>\#{pages}</body>
          </html>
          \"""
        end
      end

  For templates that need Chrome-level headers/footers or other ChromicPDF
  options, return a `%{source: source, opts: opts}` map or a list of them:

      defmodule MyApp.PDF.PickupListTemplate do
        @behaviour AshQuick.PrintTemplate

        @impl true
        def label, do: "Pickup List"

        @impl true
        def load_opts do
          [:customer, :assigned_to, transfers: [:product]]
        end

        @impl true
        def render(records) do
          Enum.map(records, fn record ->
            ChromicPDF.Template.source_and_options(
              content: "<h1>\#{record.name}</h1>",
              size: :a4,
              header: "<p>My Header</p>",
              header_height: "15mm"
            )
          end)
        end
      end

  Then in your QuickView:

      use AshQuick.LiveView.QuickView,
        resource: MyApp.TransferBatch,
        print_templates: [MyApp.PDF.PickupListTemplate]

  """

  @doc """
  A human-readable label for this template (e.g. "Pickup List").
  Used in action buttons and file names.
  """
  @callback label() :: String.t()

  @doc """
  The load options needed to render this template.
  These are passed to `Ash.Query.load/2` when fetching records.
  """
  @callback load_opts() :: keyword()

  @doc """
  Renders a PDF for the given list of loaded records.

  Must return one of:
    - An HTML string — rendered directly by ChromicPDF with `preferCSSPageSize: true`.
      Use `@page` CSS for page size and `break-after: page` for multi-page documents.
      This is the simplest and recommended approach.
    - A `%{source: source, opts: opts}` map — passed to `ChromicPDF.print_to_pdf/2`.
      Use when you need Chrome-level headers/footers or other print options.
    - A list of `%{source: source, opts: opts}` maps — each is rendered individually
      by ChromicPDF (preserving native headers/footers/page numbers), then merged
      using MergePdf which does page-level concatenation without re-processing fonts.
  """
  @callback render(records :: [Ash.Resource.record()]) ::
              String.t()
              | %{source: term(), opts: keyword()}
              | [%{source: term(), opts: keyword()}]
end
