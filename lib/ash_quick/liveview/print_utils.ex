defmodule AshQuick.LiveView.PrintUtils do
  @moduledoc """
  Prints what an action wrote, when the action carries `AshQuick.Print`:
  renders it with ChromicPDF and pushes the PDF to the browser. Runs after the
  action has committed, so a render that fails leaves the action's writes in
  place and flashes that the PDF could not be produced.

  The PDF travels over the LiveView socket as an `"ash_quick:pdf"` event, which
  `assets/js/print.js` saves or prints. Nothing is stored and no link is
  handed out: only the tab that ran the action gets it.
  """

  require Logger
  import Phoenix.LiveView, only: [push_event: 3, put_flash: 3]

  @render_failed "It was recorded, but its PDF could not be produced. Print it again."

  @doc """
  Prints `result` — what an action returned: `{:ok, record}`, an
  `Ash.BulkResult` or what `AshPhoenix.Form.submit/2` returns — when its
  records carry a print. Anything else leaves the socket as it was.
  """
  def print(socket, result) do
    case printed(result) do
      nil -> socket
      {print, records} -> deliver(socket, print, records)
    end
  end

  # A bulk run that wrote nothing (every row stale) prints nothing either.
  defp printed({:ok, %_{} = record}), do: marked([record])
  defp printed(%Ash.BulkResult{status: :success, records: [_ | _] = records}), do: marked(records)
  defp printed(_not_written), do: nil

  # Every record came from the same action, so the first one's mark is theirs.
  defp marked([%{__metadata__: %{ash_quick_print: print}} | _] = records), do: {print, records}
  defp marked(_records), do: nil

  defp deliver(socket, print, records) do
    {filename, pdf} = render!(print.template, records, socket.assigns.scope)

    push_event(socket, "ash_quick:pdf", %{data: pdf, filename: filename, delivery: print.delivery})
  rescue
    exception ->
      Logger.error(
        "printing #{inspect(print.template)} failed after its action was recorded\n" <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      put_flash(socket, :error, @render_failed)
  end

  defp render!(template, [%resource{} | _] = records, scope) do
    records =
      Ash.load!(records, [AshQuick.Info.display_label(resource) | template.load_opts()],
        scope: scope
      )

    {filename(template, resource, records), render_pdf!(template.render(records))}
  end

  # ChromicPDF hands back base64, which is what the event carries.
  defp render_pdf!(html) when is_binary(html) do
    {:ok, pdf} = ChromicPDF.print_to_pdf({:html, html}, print_to_pdf: %{preferCSSPageSize: true})
    pdf
  end

  defp render_pdf!(%{source: source, opts: opts}) do
    {:ok, pdf} = ChromicPDF.print_to_pdf(source, opts)
    pdf
  end

  # Each source rendered on its own keeps Chrome's headers, footers and page
  # numbers; MergePdf joins the pages without re-processing fonts, which
  # Ghostscript's pdfwrite mangles.
  defp render_pdf!(sources) when is_list(sources) do
    {:ok, merged} =
      sources
      |> Enum.map(&(&1 |> render_pdf!() |> Base.decode64!()))
      |> MergePdf.merge_binaries()

    Base.encode64(merged)
  end

  defp filename(template, resource, records) do
    label = template.label() |> String.downcase() |> String.replace(" ", "_")
    date = AshQuick.Config.now_in_timezone() |> Calendar.strftime("%y-%m-%d-%H-%M-%S")

    name =
      case records do
        [record] ->
          "#{AshQuick.Info.display_value(record) || record.id}_#{label}"

        _ ->
          "#{Ash.Resource.Info.plural_name(resource)}_#{label}_#{length(records)}"
      end

    "#{name}-#{date}.pdf"
  end
end
