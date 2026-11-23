defmodule AshQuick.LiveView.Components.PickerInput do
  @moduledoc false
  # A form field drawn as an `AshQuick.LiveView.Picker`, with its label, help
  # and errors, for `ChoiceInput`, `BelongsToInput` and `HasManyInput`, which
  # each draw it in their own root tag, as a live component must. The
  # picker's text box takes the field's id, so the label points at it, and it
  # is described by the help and the errors drawn under it. Kept out of
  # `AshQuick.Components`, which a host's QuickView imports whole.
  use Phoenix.Component
  import AshQuick.LiveView.Components.RecordOption

  alias AshQuick.LiveView.Components.FieldHelp
  alias AshQuick.LiveView.FieldErrors

  attr :field, Phoenix.HTML.FormField, required: true
  attr :mode, :atom, required: true, values: [:single, :tags]
  attr :search, :any, required: true
  attr :resolve, :any, required: true
  attr :label, :string, default: nil
  attr :required, :boolean, default: false
  attr :help, :string, default: nil
  attr :placeholder, :string, default: nil
  attr :records, :boolean, default: false, doc: "draws each option's hint, as a record's"

  def picker_input(assigns) do
    field = assigns.field
    errors = FieldErrors.for_select(field)

    assigns =
      assign(assigns,
        errors: errors,
        label_id: assigns.label && "#{field.id}-label",
        help_id: assigns.help && FieldHelp.id(field.id),
        errors_id: errors != [] && "#{field.id}-errors"
      )

    ~H"""
    <label :if={@label} id={@label_id} for={@field.id} class="label text-sm font-medium">
      {@label}
    </label>
    <span :if={@required} class="text-error"> &ast;</span>
    <.live_component
      module={AshQuick.LiveView.Picker}
      id={"#{@field.id}-picker"}
      field={@field}
      mode={@mode}
      search={@search}
      resolve={@resolve}
      clearable={@mode == :single}
      placeholder={@placeholder}
      label_id={@label_id}
      describedby={[@help_id, @errors_id]}
      invalid={@errors != []}
    >
      <:option :let={option} :if={@records}><.record_option option={option} /></:option>
      <%!-- A single pick shows its hint beside it, as the picker draws it. --%>
      <:tag :let={option} :if={@records and @mode == :tags}>
        <.record_tag option={option} />
      </:tag>
    </.live_component>

    <FieldErrors.used_marker field={@field} />
    <FieldHelp.help id={@field.id} text={@help} />
    <div :if={@errors != []} id={@errors_id}>
      <AshQuick.Components.error :for={msg <- @errors}>{msg}</AshQuick.Components.error>
    </div>
    """
  end
end
