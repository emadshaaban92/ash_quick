defmodule AshQuick.LiveView.Components.FormView do
  @moduledoc false
  use Phoenix.Component
  use Gettext, backend: AshQuick.Gettext
  import AshQuick.Components

  alias Ash.Resource.Relationships.BelongsTo
  alias Ash.Resource.Actions.Argument
  alias Ash.Type
  alias AshQuick.Labels
  alias Phoenix.LiveView.JS

  alias AshQuick.LiveView.EnumOptions
  alias AshQuick.LiveView.FieldErrors
  alias AshQuick.LiveView.FormUtils
  alias AshQuick.LiveView.Utils
  alias AshQuick.LiveView.URLParams

  def form_view(assigns) do
    forbidden? = forbidden?(assigns)

    assigns =
      assigns
      |> assign_new(:uploads, fn -> nil end)
      |> assign_new(:ash_quick_background, fn -> nil end)
      |> assign(:forbidden?, forbidden?)
      |> assign(:confirm?, not forbidden? and Enum.empty?(fields(assigns.form, assigns.scope)))

    ~H"""
    <section class="p-3 sm:p-5">
      <.confirm_form :if={@confirm?} {confirm_assigns(assigns)} />
      <.simple_form
        :if={not @forbidden? and not @confirm?}
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
        <:actions>
          <.cancel_link background={@ash_quick_background} class="mt-4 sm:mt-6 ml-2" />
        </:actions>
      </.simple_form>
      <.forbidden_action :if={@forbidden?} base_path={@base_path} params={@params} />
    </section>
    """
  end

  defp fields(form, scope), do: Utils.action_fields(form.resource, form.action, scope)

  defp confirm_assigns(assigns) do
    Map.take(assigns, [:form, :id, :ash_action, :record, :ash_quick_background])
  end

  attr :form, :any, default: nil
  attr :id, :string, required: true
  attr :ash_action, :map, required: true
  attr :record, :any, default: nil
  attr :ash_quick_background, :map, default: nil
  attr :close, :any, default: nil, doc: "closes the modal instead of `ash_quick_background`"
  attr :submit, :string, default: "save"
  attr :applies_to, :integer, default: nil, doc: "how many selected rows a bulk run writes"

  # An action that asks for nothing is a confirmation rather than a form: the
  # action and what it acts on, and the one button that runs it.
  @doc false
  def confirm_form(assigns) do
    ~H"""
    <.form
      for={@form || %{}}
      id={@id}
      phx-submit={@submit}
      phx-hook="AshQuick.Components.SubmitLock"
      class="flex flex-col gap-4"
    >
      <h3 class="text-lg font-semibold">{Labels.name(@ash_action.name)}</h3>
      <p :if={@ash_action.type != :create and @record} class="font-medium">
        {AshQuick.Info.display_value(@record)}
      </p>
      <p :if={@applies_to} class="font-medium">
        {ngettext(
          "Applies to 1 selected row.",
          "Applies to %{count} selected rows.",
          @applies_to
        )}
      </p>
      <p class="text-base-content/70">{gettext("Are you sure?")}</p>
      <div class="flex justify-end gap-2">
        <.cancel_link background={@ash_quick_background} close={@close} />
        <button
          type="submit"
          class={[
            "btn phx-submit-loading:bg-(--btn-color) phx-submit-loading:text-(--btn-fg)",
            if(@ash_action.type == :destroy, do: "btn-error", else: "btn-primary")
          ]}
        >
          <span class="phx-submit-loading:opacity-0">{gettext("Confirm")}</span>
          <span
            class="loading loading-spinner loading-sm absolute hidden phx-submit-loading:inline-block"
            aria-hidden="true"
          />
        </button>
      </div>
    </.form>
    """
  end

  attr :background, :map, default: nil
  attr :close, :any, default: nil, doc: "a path or a `JS` command, in place of `background`"
  attr :class, :string, default: nil

  # Back to the page the modal opened over, without running anything. A
  # button rather than a link, so LiveView disables it with the rest of the
  # form while the action runs: a link would stay live to the keyboard.
  @doc false
  def cancel_link(assigns) do
    assigns =
      assign(assigns, :close, assigns.close || (assigns.background && assigns.background.path))

    ~H"""
    <button
      :if={@close}
      type="button"
      phx-click={AshQuick.LiveView.Components.ActionModal.close_js(@close)}
      class={["btn btn-ghost", @class]}
    >
      {gettext("Cancel")}
    </button>
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
  defp forbidden?(%{type: type}, nil, _resource, _scope) when type in [:update, :destroy],
    do: true

  # A create form has no record by nature — fall back to a record-less check.
  defp forbidden?(action, nil, resource, scope), do: not can_run?({resource, action}, scope)

  defp forbidden?(action, record, _resource, scope), do: not can_run?({record, action}, scope)

  # Asked as the run will be stamped, so a policy refusing the form source
  # shows the forbidden panel here rather than a form whose submit it refuses.
  defp can_run?(target, scope) do
    Ash.can?(target, scope,
      log_policy_breakdown?: false,
      context: %{action_source: AshQuick.form_source()}
    )
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
          choice={EnumOptions.kind(field)}
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

  # A `sensitive?` input never carries the stored value: the page would hold
  # it in plain sight. It shows only what was typed into this form, and on an
  # update a blank one keeps the value — `FormUtils` drops it from the params.
  defp field_input(%{field: %{sensitive?: true}} = assigns) do
    assigns =
      assigns
      |> assign(:typed, Map.get(assigns.phx_field.form.params, to_string(assigns.field.name)))
      |> assign(:update?, assigns.phx_field.form.source.type == :update)

    ~H"""
    <.input
      required={not @field.allow_nil? and not @update?}
      field={@phx_field}
      value={@typed}
      type="password"
      autocomplete="one-time-code"
      placeholder={if @update?, do: gettext("Leave blank to keep it")}
      label={Labels.name(@field.name)}
      phx-debounce="blur"
    />
    """
  end

  defp field_input(%{field: %Argument{type: {:array, item_type}}} = assigns)
       when item_type in [Type.UUID, Type.UUIDv7] do
    case Utils.argument_to_relationship(assigns.field, assigns.resource, assigns.form.action) do
      %Ash.Resource.Relationships.ManyToMany{} = relationship ->
        assigns = assign(assigns, relationship: relationship)

        ~H"""
        <.live_component
          :if={@relationship}
          required={not @field.allow_nil?}
          id={"select-#{@field.name}"}
          module={AshQuick.LiveView.Components.HasManyInput}
          label={Labels.name(@relationship.name)}
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
      label={Labels.name(@field.name)}
      relationship={@field}
      scope={@scope}
      form={@form |> to_form()}
    />
    """
  end

  # A value picked from a fixed set (`AshQuick.LiveView.EnumOptions`): an
  # `Ash.Type.Enum`, or an atom with `one_of`, alone or in a list.
  defp field_input(%{choice: choice} = assigns) when choice in [:single, :array] do
    ~H"""
    <.live_component
      id={"select-#{@field.name}"}
      required={not @field.allow_nil?}
      module={AshQuick.LiveView.Components.ChoiceInput}
      multiple={@choice == :array}
      label={Labels.name(@field.name)}
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
      assigns.field
      |> attachment_value(assigns.phx_field)
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.filter(&match?({%AshQuick.AshTypes.Attachment.Value{}, _}, &1))

    name = assigns.field.name |> Labels.name() |> String.downcase()

    prompt =
      if rows == [],
        do: gettext("Add %{name}", name: name),
        else: gettext("Add more %{name}", name: name)

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
      |> assign(
        :states,
        rows |> Enum.map(&elem(&1, 0)) |> AshQuick.Storage.states_for(scope: assigns[:scope])
      )
      |> assign(:errors, FieldErrors.for_hidden_input(assigns.phx_field))

    ~H"""
    <section
      phx-drop-target={@upload.ref}
      data-attachment-field={@field.name}
      class="flex flex-col gap-2 sm:col-span-4 card bg-base-100 p-5 my-3 phx-submit-loading:pointer-events-none"
    >
      <h3 class="font-semibold">{Labels.name(@field.name)}</h3>
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
      <.attachment_dropzone upload={@upload} prompt={@prompt} />
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
      assigns.field
      |> attachment_value(assigns.phx_field)
      |> List.wrap()
      |> Enum.filter(&match?(%AshQuick.AshTypes.Attachment.Value{}, &1))

    assigns =
      assigns
      |> assign(:upload_name, upload_name)
      |> assign(:saved_values, saved_values)
      |> assign(:states, AshQuick.Storage.states_for(saved_values, scope: assigns[:scope]))
      |> assign(:errors, FieldErrors.for_hidden_input(assigns.phx_field))

    ~H"""
    <section
      phx-drop-target={@uploads[@upload_name].ref}
      data-attachment-field={@field.name}
      class="flex flex-col sm:col-span-2 card bg-base-100 p-5 my-3 phx-submit-loading:pointer-events-none"
    >
      <div class="flex justify-between">
        <label for={@uploads[@upload_name].ref}>
          {if @field.name != :attachment, do: Labels.name(@field.name)}
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
      the type casts back. A bare input: the field's errors render once, below. --%>
      <input
        type="hidden"
        name={@phx_field.name}
        value={attachment_input_value(attachment_value(@field, @phx_field))}
      />
      <.error :for={msg <- @errors}>{msg}</.error>

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
      label={Labels.name(@field.name)}
      phx-debounce="blur"
    />
    """
  end

  defp field_input(%{form_key_type: :list, phx_field: phx_field} = assigns) do
    assigns = assigns |> assign(:errors, FieldErrors.for_field(phx_field))

    ~H"""
    <section class="sm:col-span-4 card bg-base-100 p-5 my-3">
      <h3 class="text-lg font-semibold mb-3">
        {Labels.name(@field.name)}
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
          <button
            type="button"
            phx-click="remove-form"
            phx-value-path={nested_phx_form.name}
            class="btn btn-ghost btn-sm btn-square"
          >
            <.icon name="hero-x-mark" />
          </button>
        </div>
      </.inputs_for>

      <button
        type="button"
        phx-click="add-form"
        phx-value-path={@form.name <> "[#{@field.name}]"}
        class="btn btn-ghost btn-sm"
      >
        <.icon name="hero-plus" /> {gettext("Add")}
      </button>

      <.error :for={msg <- @errors}>{msg}</.error>
    </section>
    """
  end

  defp field_input(%{form_key_type: :single, phx_field: phx_field} = assigns) do
    assigns = assigns |> assign(:errors, FieldErrors.for_field(phx_field))

    ~H"""
    <.inputs_for :let={nested_phx_form} field={@phx_field}>
      <.form_fields
        form={nested_phx_form.source}
        scope={@scope}
        uploads={@uploads}
        title={Labels.name(@field.name)}
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
        label={Labels.name(@field.name)}
        phx-debounce="blur"
      />
    </div>
    """
  end

  defp field_input(%{field: %{type: Type.Boolean}} = assigns) do
    ~H"""
    <.input field={@phx_field} type="checkbox" label={Labels.name(@field.name)} />
    """
  end

  defp field_input(%{field: %{}} = assigns) do
    ~H"""
    <.input
      required={not @field.allow_nil?}
      field={@phx_field}
      type="text"
      autocomplete="on"
      label={Labels.name(@field.name)}
      phx-debounce="blur"
    />
    """
  end

  # What an attachment field holds. An attribute reads as the form reads it,
  # falling back to the record's value. An argument holds only what the action
  # was given: `AshPhoenix.Form.value/2` would also fall back to whatever the
  # record holds under the same name, which is not the argument's to show or to
  # post back.
  defp attachment_value(%Ash.Resource.Attribute{}, phx_field), do: phx_field.value

  defp attachment_value(field, %{form: %{source: %AshPhoenix.Form{source: source}}}) do
    with :error <- fetch_argument(source, field.name),
         :error <- Map.fetch(source.params || %{}, to_string(field.name)) do
      nil
    else
      {:ok, value} -> value
    end
  end

  defp attachment_value(_field, phx_field), do: phx_field.value

  defp fetch_argument(%Ash.Changeset{} = changeset, name),
    do: Ash.Changeset.fetch_argument(changeset, name)

  defp fetch_argument(%Ash.ActionInput{} = input, name),
    do: Ash.ActionInput.fetch_argument(input, name)

  defp fetch_argument(_source, _name), do: :error

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
