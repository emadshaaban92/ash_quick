defmodule AshQuick.LiveView.Components.BulkActionView do
  @moduledoc false
  # What the action modal holds for a bulk action: a confirmation for one that
  # takes no input, a form for one that does. Who may run it is the run's to
  # decide, row by row. Built from `FormView`'s parts, so a bulk form renders its
  # fields, widgets and field policies exactly as the single form does.
  use Phoenix.Component
  use Gettext, backend: AshQuick.Gettext
  import AshQuick.Components

  alias AshQuick.Labels
  alias AshQuick.LiveView.Components.{ActionModal, FormView}
  alias Phoenix.LiveView.JS

  @doc false
  # The page, under the open bulk action's modal if there is one. Called with
  # the LiveView's own assigns, so the page underneath keeps its change
  # tracking.
  def with_page(%{ash_quick_bulk: %{}} = assigns, page) do
    assigns = assign(assigns, :ash_quick_page, page)

    ~H"""
    <div inert>{@ash_quick_page}</div>
    <ActionModal.action_modal class="w-11/12 max-w-5xl p-0" close={JS.push("bulk_close")}>
      <.bulk_action_view
        bulk={@ash_quick_bulk}
        resource={@resource}
        scope={@scope}
        selected_rows={@selected_rows}
        data={@data}
        widgets={@options.form_widgets}
      />
    </ActionModal.action_modal>
    """
  end

  def with_page(_assigns, page), do: page

  attr :bulk, :map, required: true
  attr :resource, :atom, required: true
  attr :scope, :any, required: true
  attr :selected_rows, :map, required: true
  attr :data, :map, required: true
  attr :widgets, :map, default: %{}

  # Counted against the rows the list holds now, which is what the run takes:
  # a selected row a live update took off the list is not run.
  def bulk_action_view(assigns) do
    assigns =
      assigns
      |> assign(:close, JS.push("bulk_close"))
      |> assign(:applies_to, applies_to(assigns.selected_rows, assigns.data))

    ~H"""
    <section class="p-3 sm:p-5">
      <FormView.confirm_form
        :if={is_nil(@bulk.form)}
        id="ash-quick-bulk-action"
        ash_action={@bulk.action}
        resource={@resource}
        close={@close}
        submit="bulk_save"
        applies_to={@applies_to}
      />
      <.simple_form
        :if={@bulk.form}
        for={@bulk.form}
        id="ash-quick-bulk-action"
        phx-change="bulk_validate"
        phx-submit="bulk_save"
        form_title={Labels.name(@bulk.action.name, @resource)}
      >
        <p class="sm:col-span-2 font-medium">
          {ngettext(
            "Applies to 1 selected row.",
            "Applies to %{count} selected rows.",
            @applies_to
          )}
        </p>
        <FormView.form_fields
          form={@bulk.form}
          scope={@scope}
          uploads={nil}
          widgets={@widgets}
          title={nil}
        />
        <:actions>
          <FormView.cancel_link close={@close} class="mt-4 sm:mt-6 ml-2" />
        </:actions>
      </.simple_form>
    </section>
    """
  end

  defp applies_to(selected_rows, data) do
    Enum.count(data.results, &(selected_rows[&1.id] == "on"))
  end
end
