defmodule AshQuick.LiveView.PrintUtils do
  @moduledoc """
  Runs an action from a QuickView surface and, when the action prints
  (`AshQuick.Print`), renders what it wrote with ChromicPDF and pushes the PDF
  to the browser — all inside the action's transaction, so a render that fails
  records nothing.

  The PDF travels over the LiveView socket as an `"ash_quick:pdf"` event, which
  `assets/js/print.js` saves or prints. Nothing is stored and no link is
  handed out: only the tab that ran the action gets it.
  """

  import Phoenix.LiveView, only: [push_event: 3]

  # The render runs inside the transaction, holding whatever the action locked.
  @timeout :timer.minutes(1)

  @doc """
  Runs `run`, which runs `action_name` on `resource` with the options it is
  given added to its own, and returns what it returned — `{:ok, record}`, an
  `Ash.BulkResult` or what `AshPhoenix.Form.submit/2` returns — with the
  socket, which carries the PDF when the action printed.
  """
  def run(socket, resource, action_name, run) do
    case AshQuick.Print.of(resource, action_name) do
      nil -> {run.([]), socket}
      print -> run_and_print(socket, resource, print, run)
    end
  end

  defp run_and_print(socket, resource, print, run) do
    scope = socket.assigns.scope

    resource
    |> Ash.transact(
      fn ->
        # The transaction is ours to roll back: an action rolling it back itself
        # would throw past the surface, which then has no result to show.
        result = run.(rollback_on_error?: false)

        case written(result) do
          # `Ash.transact/3` wraps what this returns in `{:ok, _}` itself.
          {:ok, records} -> {result, render!(print.template, resource, records, scope)}
          :error -> {:error, {:not_written, result}}
        end
      end,
      timeout: @timeout
    )
    |> case do
      {:ok, {result, {filename, pdf}}} ->
        {result,
         push_event(socket, "ash_quick:pdf", %{
           data: pdf,
           filename: filename,
           delivery: print.delivery
         })}

      {:error, {:not_written, result}} ->
        {result, socket}
    end
  end

  # A bulk run that wrote nothing (every row stale) prints nothing either.
  defp written({:ok, %_{} = record}), do: {:ok, [record]}
  defp written(%Ash.BulkResult{status: :success, records: [_ | _] = records}), do: {:ok, records}
  defp written(_not_written), do: :error

  defp render!(template, resource, records, scope) do
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
