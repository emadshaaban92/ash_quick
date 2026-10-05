defmodule AshQuick.LiveView.Components.FormView do
  @moduledoc false
  use Phoenix.Component
  use Gettext, backend: AshQuick.Gettext
  import AshQuick.Components

  alias Ash.Resource.Relationships.BelongsTo
  alias Ash.Resource.Actions.Argument
  alias Ash.Type
  alias Phoenix.LiveView.JS

  alias AshQuick.LiveView.FormUtils
  alias AshQuick.LiveView.Utils
  alias AshQuick.LiveView.URLParams

  def form_view(assigns) do
    forbidden? = forbidden?(assigns)

    assigns =
      assigns
      |> assign_new(:uploads, fn -> nil end)
      |> assign(:forbidden?, forbidden?)

    ~H"""
    <section class="p-3 sm:p-5">
      <.simple_form
        :if={not @forbidden?}
        for={@form}
        id={@id}
        phx-change="validate"
        phx-submit="save"
        form_title={@page_title}
      >
        <.form_fields
          form={@form}
          scope={@scope}
          uploads={@uploads}
          widgets={@options.form_widgets}
          title={nil}
        />
      </.simple_form>
      <.forbidden_action :if={@forbidden?} base_path={@base_path} params={@params} />
    </section>
    """
  end

  @doc """
  Whether the actor may not run this form's action.

  Also consulted by the custom `action_*` template dispatch in
  `AshQuick.LiveView.QuickView`: such a template replaces this view wholesale,
  so it is skipped when the answer is `true` and the forbidden panel renders
  in its place.
  """
  def forbidden?(assigns) do
    forbidden?(assigns.ash_action, assigns[:record], assigns.resource, assigns.scope)
  end

  # An update form with no record: the actor cannot read it, or it does not
  # exist. Both look the same from here, and neither offers an action to run.
  defp forbidden?(%{type: :update}, nil, _resource, _scope), do: true

  # A create form has no record by nature — fall back to a record-less check.
  defp forbidden?(action, nil, resource, scope) do
    not Ash.can?({resource, action}, scope, log_policy_breakdown?: false)
  end

  defp forbidden?(action, record, _resource, scope) do
    not Ash.can?({record, action}, scope, log_policy_breakdown?: false)
  end

  def form_fields(%{form: form, scope: scope} = assigns) do
    assigns =
      assigns
      |> assign(:fields, Utils.action_fields(form.resource, form.action, scope))
      |> assign(:phx_form, form |> to_form())
      |> assign_new(:widgets, fn -> %{} end)

    ~H"""
    <section class="sm:col-span-4 card card-border border-base-300 shadow-lg bg-base-200/30 p-5 my-3">
      <h3 :if={@title} class="text-lg font-semibold mb-3">
        {@title}
      </h3>
      <div class="grid gap-4 sm:grid-cols-4 sm:gap-6">
        <.field_input
          :for={field <- @fields}
          form={@form}
          field={field}
          phx_field={@phx_form[field.name]}
          resource={@form.resource}
          scope={@scope}
          uploads={@uploads}
          form_key_type={@form.form_keys[field.name][:type]}
          widget={Map.get(@widgets, field.name)}
        />
      </div>
    </section>
    """
  end

  # A configured widget replaces this field's input entirely. It receives the
  # same assigns the built-in clauses do — `@field`, `@phx_field`, `@form`,
  # `@uploads`, `@scope` — so it can render its own controls over the same
  # `AshPhoenix.Form`. Only the top-level fields of the action are matched:
  # nested embed sub-forms render through `form_fields/1` without a widget map,
  # since the key is a bare field name and would otherwise collide with a
  # same-named field one level down.
  defp field_input(%{widget: widget} = assigns) when is_function(widget) do
    widget.(assigns)
  end

  defp field_input(%{field: %Argument{type: {:array, item_type}}} = assigns)
       when item_type in [Type.UUID, Type.UUIDv7] do
    case Utils.argument_to_relationship(assigns.field, assigns.resource) do
      %Ash.Resource.Relationships.ManyToMany{} = relationship ->
        assigns = assign(assigns, relationship: relationship)

        ~H"""
        <.live_component
          :if={@relationship}
          required={not @field.allow_nil?}
          id={"select-#{@field.name}"}
          module={AshQuick.LiveView.Components.HasManyInput}
          label={@relationship.name |> Utils.humanize()}
          relationship={@relationship}
          scope={@scope}
          form={@form |> to_form()}
          argument_name={@field.name}
        />
        """

      _ ->
        ~H""
    end
  end

  defp field_input(%{field: %BelongsTo{}} = assigns) do
    ~H"""
    <.live_component
      id={"select-#{@field.name}"}
      required={not @field.allow_nil?}
      module={AshQuick.LiveView.Components.BelongsToInput}
      label={@field.name |> Utils.humanize()}
      relationship={@field}
      scope={@scope}
      form={@form |> to_form()}
    />
    """
  end

  defp field_input(%{field: %{type: Type.Atom}} = assigns) do
    ~H"""
    <.live_component
      id={"select-#{@field.name}"}
      required={not @field.allow_nil?}
      module={AshQuick.LiveView.Components.AtomInput}
      label={@field.name |> Utils.humanize()}
      attribute={@field}
      scope={@scope}
      form={@form |> to_form()}
    />
    """
  end

  defp field_input(%{field: %{type: {:array, Type.Atom}}} = assigns) do
    ~H"""
    <.live_component
      id={"select-#{@field.name}"}
      required={not @field.allow_nil?}
      module={AshQuick.LiveView.Components.ArrayOfAtomInput}
      label={@field.name |> Utils.humanize()}
      attribute={@field}
      scope={@scope}
      form={@form |> to_form()}
    />
    """
  end

  # An array of attachments: a row per stored file, each with a ✕, over a drop
  # zone for more. Nothing here posts the list — the form holds it on the server
  # (`FormUtils.carry_uploaded_attachments/2`), an upload appends to it, and the
  # ✕ names a position. Stored rows stay up while a pick uploads, so the pick
  # reads as an addition rather than a replacement.
  defp field_input(%{field: %{type: {:array, AshQuick.AshTypes.Attachment}}} = assigns) do
    upload = assigns.uploads["#{assigns.phx_field.name}_upload"]

    # Positions are counted before anything is filtered out, so a ✕ names the
    # same position in the list the form holds.
    rows =
      assigns.phx_field.value
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.filter(&match?({%AshQuick.AshTypes.Attachment.Value{}, _}, &1))

    name = assigns.field.name |> Utils.humanize() |> String.downcase()

    prompt =
      if rows == [],
        do: gettext("Add %{name}", name: name),
        else: gettext("Add more %{name}", name: name)

    errors =
      if Phoenix.Component.used_input?(assigns.phx_field), do: assigns.phx_field.errors, else: []

    # Only the root form's attributes hold their list on the server. An argument
    # is the action's to fold, and a nested form's params are not addressed from
    # the root, so their rows have no ✕ that could do anything.
    removable? =
      match?(%Ash.Resource.Attribute{}, assigns.field) and
        not String.contains?(assigns.form.name, "[")

    assigns =
      assigns
      |> assign(:upload, upload)
      |> assign(:removable?, removable?)
      |> assign(:rows, rows)
      |> assign(:prompt, prompt)
      |> assign(:states, rows |> Enum.map(&elem(&1, 0)) |> AshQuick.Storage.states_for())
      |> assign(:errors, Enum.map(errors, &translate_error(&1)))

    ~H"""
    <section
      phx-drop-target={@upload.ref}
      data-attachment-field={@field.name}
      class="flex flex-col gap-2 sm:col-span-4 card bg-base-100 p-5 my-3"
    >
      <h3 class="font-semibold">{Utils.humanize(@field.name)}</h3>
      <ul :if={@rows != []} class="divide-y divide-base-300">
        <.attachment_row
          :for={{value, index} <- @rows}
          value={value}
          states={@states}
          on_remove={
            @removable? && JS.push("remove-attachment", value: %{field: @field.name, index: index})
          }
        />
      </ul>
      <.attachment_dropzone upload={@upload} id={@phx_field.id} prompt={@prompt} />
      <.error :for={msg <- @errors}>{msg}</.error>
    </section>
    """
  end

  defp field_input(%{field: %{type: AshQuick.AshTypes.Attachment}} = assigns) do
    upload_name = "#{assigns.phx_field.name}_upload"

    # Only values that resolved to an attachment can be previewed. An argument
    # of this type posts back an empty string when nothing was picked, and a
    # param that failed to cast stays a raw string — neither is previewable, and
    # both reach here before the field has an error to render instead.
    saved_values =
      assigns.phx_field.value
      |> List.wrap()
      |> Enum.filter(&match?(%AshQuick.AshTypes.Attachment.Value{}, &1))

    assigns =
      assigns
      |> assign(:upload_name, upload_name)
      |> assign(:saved_values, saved_values)
      |> assign(:states, AshQuick.Storage.states_for(saved_values))

    ~H"""
    <section
      phx-drop-target={@uploads[@upload_name].ref}
      class="flex flex-col sm:col-span-2 card bg-base-100 p-5 my-3"
    >
      <div class="flex justify-between">
        <label for={@uploads[@upload_name].ref}>
          {if @field.name != :attachment, do: Utils.humanize(@field.name)}
        </label>
        <div :if={@uploads[@upload_name].entries |> Enum.empty?()} class="flex flex-wrap gap-2">
          <AshQuick.LiveView.Components.FieldValue.attachment_preview
            :for={value <- @saved_values}
            value={value}
            states={@states}
          />
        </div>
      </div>
      <.live_file_input
        upload={@uploads[@upload_name]}
        id={@phx_field.id}
        class="file-input w-full"
      />
      <%!-- Carries an existing attachment across a validate round trip, as the JSON
      the type casts back. --%>
      <.input
        type="hidden"
        field={@phx_field}
        value={attachment_input_value(@phx_field.value)}
      />

      <%= for entry <- @uploads[@upload_name].entries do %>
        <div class="flex items-center gap-2 mt-2 text-sm text-base-content/70">
          <.icon name={entry_icon(entry.client_type)} class="w-4 h-4" />
          <span class="truncate">{entry.client_name}</span>
        </div>
        <progress class="progress progress-primary w-full mt-2" value={entry.progress} max="100">
          {entry.progress}%
        </progress>

        <button
          type="button"
          phx-click="cancel-upload"
          phx-value-entry={@uploads[@upload_name].name}
          phx-value-ref={entry.ref}
          aria-label={gettext("cancel")}
          class="btn btn-ghost btn-xs mt-1"
        >
          &times;
        </button>

        <p :for={err <- upload_errors(@uploads[@upload_name], entry)} class="text-error text-sm mt-1">
          {FormUtils.upload_error_message(err)}
        </p>
      <% end %>
    </section>
    """
  end

  defp field_input(%{field: %{type: field_type}} = assigns)
       when field_type in [Ash.Type.DateTime, Ash.Type.UtcDatetimeUsec, Ash.Type.UtcDatetime] do
    ~H"""
    <.input
      required={not @field.allow_nil?}
      field={@phx_field}
      type="datetime-local"
      label={@field.name |> Utils.humanize()}
      phx-debounce="blur"
    />
    """
  end

  defp field_input(%{form_key_type: :list, phx_field: phx_field} = assigns) do
    errors = if Phoenix.Component.used_input?(phx_field), do: phx_field.errors, else: []
    assigns = assigns |> assign(:errors, Enum.map(errors, &translate_error(&1)))

    ~H"""
    <section class="sm:col-span-4 card bg-base-100 p-5 my-3">
      <h3 class="text-lg font-semibold mb-3">
        {@field.name |> Utils.humanize()}
      </h3>

      <.inputs_for :let={nested_phx_form} field={@phx_field}>
        <div class="flex justify-between">
          <div class="grow grid gap-4 sm:grid-cols-4 sm:gap-6">
            <.form_fields
              form={nested_phx_form.source}
              scope={@scope}
              uploads={@uploads}
              title={nil}
            />
          </div>
          <.link
            phx-click="remove-form"
            phx-value-path={nested_phx_form.name}
            class="btn btn-ghost btn-sm btn-square"
          >
            <.icon name="hero-x-mark" />
          </.link>
        </div>
      </.inputs_for>

      <.link
        phx-click="add-form"
        phx-value-path={@form.name <> "[#{@field.name}]"}
        class="btn btn-ghost btn-sm"
      >
        <.icon name="hero-plus" /> {gettext("Add")}
      </.link>

      <.error :for={msg <- @errors}>{msg}</.error>
    </section>
    """
  end

  defp field_input(%{form_key_type: :single, phx_field: phx_field} = assigns) do
    errors = if Phoenix.Component.used_input?(phx_field), do: phx_field.errors, else: []
    assigns = assigns |> assign(:errors, Enum.map(errors, &translate_error(&1)))

    ~H"""
    <.inputs_for :let={nested_phx_form} field={@phx_field}>
      <.form_fields
        form={nested_phx_form.source}
        scope={@scope}
        uploads={@uploads}
        title={@field.name |> Utils.humanize()}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </.inputs_for>
    """
  end

  defp field_input(%{field: %{type: AshQuick.AshTypes.Text}} = assigns) do
    ~H"""
    <div class="sm:col-span-4">
      <.input
        required={not @field.allow_nil?}
        field={@phx_field}
        type="textarea"
        label={@field.name |> Utils.humanize()}
        phx-debounce="blur"
      />
    </div>
    """
  end

  defp field_input(%{field: %{type: Type.Boolean}} = assigns) do
    ~H"""
    <.input field={@phx_field} type="checkbox" label={@field.name |> Utils.humanize()} />
    """
  end

  defp field_input(%{field: %{}} = assigns) do
    ~H"""
    <.input
      required={not @field.allow_nil?}
      field={@phx_field}
      type={if @field.sensitive?, do: "password", else: "text"}
      autocomplete={if @field.sensitive?, do: "one-time-code", else: "on"}
      label={@field.name |> Utils.humanize()}
      phx-debounce="blur"
    />
    """
  end

  defp attachment_input_value(nil), do: nil
  defp attachment_input_value(%AshQuick.AshTypes.Attachment.Value{} = v), do: Jason.encode!(v)
  defp attachment_input_value(value) when is_binary(value), do: value
  defp attachment_input_value(_), do: nil

  defp forbidden_action(assigns) do
    ~H"""
    <div class="flex items-center justify-center min-h-96 p-8">
      <div class="card bg-base-100 shadow-lg border border-error/30 max-w-md w-full">
        <div class="card-body items-center text-center">
          <div class="w-16 h-16 bg-error/10 rounded-full flex items-center justify-center">
            <.icon name="hero-shield-exclamation" class="w-8 h-8 text-error" />
          </div>
          <h3 class="card-title text-base-content">
            {gettext("Access Forbidden")}
          </h3>
          <p class="text-base-content/70">
            {gettext(
              "You do not have permission to perform this action. Please contact an administrator if you believe this is an error."
            )}
          </p>
          <div class="card-actions mt-4">
            <.link navigate="/" class="btn btn-ghost btn-sm">
              <.icon name="hero-home" class="w-4 h-4" /> {gettext("Go Home")}
            </.link>
            <.link
              patch={URLParams.full_path(@base_path, @params |> URLParams.to_list_params())}
              class="btn btn-error btn-sm"
            >
              <.icon name="hero-arrow-left" class="w-4 h-4" /> {gettext("Go Back")}
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp entry_icon("video/" <> _), do: "hero-film"
  defp entry_icon("application/pdf"), do: "hero-document"
  defp entry_icon(_client_type), do: "hero-photo"
end
