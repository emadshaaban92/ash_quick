defmodule AshQuick.LiveView.Components.PrintModal do
  @moduledoc false
  use Phoenix.Component
  use Gettext, backend: AshQuick.Gettext
  import AshQuick.Components

  @doc """
  Renders a modal for PDF generation progress and download.

  Expects a `print_data` assign from `assign_async/3`. Shows a spinner while
  loading, a download link on success, and an error message on failure.

  ## Usage

      <AshQuick.LiveView.Components.PrintModal.print_modal print_data={@print_data} />

  Or import and use directly:

      import AshQuick.LiveView.Components.PrintModal
      ...
      <.print_modal print_data={@print_data} />
  """

  attr :print_data, :any, default: nil

  def print_modal(assigns) do
    ~H"""
    <dialog
      :if={@print_data && @print_data.failed != {:exit, {:shutdown, :cancel}}}
      class="modal modal-open"
    >
      <div class="modal-box">
        <div class="flex justify-between items-center mb-4">
          <h3 class="text-lg font-semibold">{gettext("Print")}</h3>
          <.link phx-click="close-print-modal" class="btn btn-sm btn-circle btn-ghost">
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </.link>
        </div>
        <div class="flex flex-col items-center justify-center py-8">
          <div :if={@print_data.loading} class="flex flex-col items-center gap-3">
            <span class="loading loading-spinner loading-lg text-primary"></span>
            <span class="text-base-content/70">{gettext("Generating PDF ...")}</span>
          </div>

          <div :if={@print_data.ok? && @print_data.result} class="flex flex-col items-center gap-4">
            <p class="text-success font-medium">{gettext("PDF generated successfully!")}</p>
            <.link
              href={@print_data.result.url}
              target="_blank"
              class="btn btn-primary"
            >
              <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> {gettext("Download PDF")}
            </.link>
          </div>

          <div :if={@print_data.failed} class="flex flex-col items-center gap-4">
            <div class="flex items-center gap-2 text-error">
              <.icon name="hero-exclamation-circle" class="w-6 h-6" />
              <p>{gettext("Failed to generate PDF")}</p>
            </div>
          </div>
        </div>
      </div>
      <div class="modal-backdrop">
        <button phx-click="close-print-modal">{gettext("close")}</button>
      </div>
    </dialog>
    """
  end
end
