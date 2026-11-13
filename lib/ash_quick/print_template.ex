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

        defp page_html(record) do
          ~s(<div class="page"><h1>\#{escape(record.name)}</h1></div>)
        end

        defp escape(value) do
          value
          |> to_string()
          |> Phoenix.HTML.html_escape()
          |> Phoenix.HTML.safe_to_string()
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
              content: "<h1>\#{escape(record.name)}</h1>",
              size: :a4,
              header: "<p>My Header</p>",
              header_height: "15mm"
            )
          end)
        end

        defp escape(value) do
          value
          |> to_string()
          |> Phoenix.HTML.html_escape()
          |> Phoenix.HTML.safe_to_string()
        end
      end

  ## Record data is untrusted

  The HTML a template returns is rendered by a Chrome running on the server,
  so markup in a record is markup Chrome acts on. A name of
  `<img src="http://10.0.0.5/admin">` makes the server request an internal
  address, and `<iframe src="file:///etc/passwd">` puts a file from the
  server's disk into the PDF the user downloads. Escaping is the protection:
  pass every value a record carries through `escape/1` as the examples do,
  in headers and footers too. Its `to_string/1` lets it take a `Decimal`, a
  `Money`, a date or `nil` as well as a string. A template written as a HEEx
  function component escapes for you; turn what it renders into a string with
  `Phoenix.HTML.Safe.to_iodata/1` and `IO.iodata_to_binary/1`.

  Escaping does not make a URL from a record safe. Chrome fetches whatever a
  `src`, a `<link>` `href` or a CSS `url()` names, escaped or not, from
  loopback, private addresses and `file://` alike. Never put a URL a record
  holds into one of them. To show an image a record points at, read its bytes
  on the server (from `AshQuick.Storage`, say) and inline them as a `data:`
  URI. If a URL from a record must go in, accept it only when it starts with
  `data:image/`, and only as a quoted `<img>` `src` attribute
  (`src="..."`), where escaping holds. Keep it out of CSS: HTML escaping
  does not protect a CSS `url()`, so a quote or a parenthesis in the value
  closes the URL and starts another.
  As an `<iframe>` or `<object>` source, `data:image/svg+xml` loads as a
  document whose own references Chrome fetches.

  ChromicPDF's own options narrow what Chrome does, but they are not a
  substitute for escaping:

      children = [
        {ChromicPDF, offline: true, disable_scripts: true}
      ]

  `disable_scripts: true` stops scripts in the page, for templates that use
  none. `offline: true` blocks frame navigations over http, such as an
  `<iframe>` to an internal address; images, stylesheets and `file://` still
  load. Inline images and fonts as `data:` URIs either way. To keep Chrome
  from reaching anything at all, run it where the network and disk hold
  nothing it should read, as ChromicPDF's "Security considerations" suggest.

  An action prints through it with `AshQuick.Print`, and its button is the
  action's own. A print that only reads writes nothing, and `accept []` keeps
  its form from offering the fields the action never writes:

      update :print_pickup_list do
        accept []
        manual fn changeset, _context -> {:ok, changeset.data} end
        change {AshQuick.Print, template: MyApp.PDF.PickupListTemplate, delivery: :download}
      end

  """

  @doc """
  A human-readable label for this template (e.g. "Pickup List"), used in the
  file name.
  """
  @callback label() :: String.t()

  @doc """
  The load options needed to render this template.
  These are passed to `Ash.Query.load/2` when fetching records.
  """
  @callback load_opts() :: keyword()

  @doc """
  Renders a PDF for the records an action wrote, loaded with `load_opts/0`, in
  the order they were selected.

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
