defmodule AshQuick.Components do
  @moduledoc """
  Core UI components used by AshQuick views.

  These are self-contained versions of the standard Phoenix CoreComponents
  that AshQuick needs. They use DaisyUI component classes for styling.

  ## Components provided

  * `icon/1` — Heroicon via CSS class
  * `attachment_img/1` — Attachment image, or a placeholder while the host
    is still holding the object
  * `label/1` — Form label
  * `error/1` — Error message
  * `button/1` — Button
  * `header/1` — Page header with title and actions
  * `simple_form/1` — Form wrapper with submit button
  * `input/1` — Form input (text, checkbox, select, textarea, etc.)

  ## Error translation

  * `translate_error/1` — Translates changeset error tuples to strings.
    By default does simple string interpolation. Configure a custom
    translator via `:error_translator` in the AshQuick config if you
    need i18n support.
  """
  use Phoenix.Component
  use Gettext, backend: AshQuick.Gettext

  ## Icons

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  ## Examples

      <.icon name="hero-x-mark-solid" />
      <.icon name="hero-arrow-path" class="ms-1 w-3 h-3 animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: nil

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  @doc """
  Renders an icon declared on an `AshQuick.Nav` entry or group.

  A string is a heroicon class; `{module, function}` and a one-argument
  function are function components, called with the `:class` this rendering
  wants and free to draw anything. Nothing is rendered for an icon that is
  not there — a group heading without one is a heading, not a gap.

  The class belongs to the caller rather than to the declaration, which is
  what lets one icon serve a sidebar, a grid tile and a menu at three
  different sizes.
  """
  attr :icon, :any, default: nil
  attr :class, :string, default: nil

  def nav_icon(%{icon: nil} = assigns) do
    ~H""
  end

  def nav_icon(%{icon: name} = assigns) when is_binary(name) do
    ~H"""
    <.icon name={@icon} class={@class} />
    """
  end

  def nav_icon(%{icon: icon, class: class}) when is_function(icon, 1) do
    icon.(%{class: class})
  end

  def nav_icon(%{icon: {module, function}, class: class}) do
    apply(module, function, [%{class: class}])
  end

  ## Attachments

  @doc """
  Renders an attachment as an `<img>`, or a placeholder in its place when the
  host is not serving that object yet.

  An object the host has taken custody of has no bytes at its serving key until
  it releases it, so pointing an `<img>` at one would render as broken.
  `AshQuick.Storage.url_for/2` says which case this is; the placeholder inherits
  `class` so the surrounding layout does not shift.

  Pass `states` — one `AshQuick.Storage.states_for/1` call for the whole page —
  wherever more than one attachment is rendered.

  ## The processing placeholder names its object

  Nothing is scanned when it is picked: the host takes custody, the bytes go to
  a holding area, and the work is enqueued only once a save references the key.
  So between picking a file and saving the form there is nothing to serve, and
  this renders "Processing" over an object that will not resolve however long
  the page waits — the browser that read the file is the only party that can
  see it.

  So the placeholder carries `data-attachment-key`, and a host may show that
  browser its own copy underneath. Just a name: nothing here reads it, no id is
  taken, and a page with no local file for the key renders exactly as it would
  have. This host does it from `assets/js/local_previews.js`.

  Beside it, `data-attachment-placeholder-class` names the classes that make it
  *look* like a placeholder, which a host putting an image in its place has to
  take back off. Stating them is what keeps the two in step: a host that kept
  its own copy would leave the grey behind the picture the day this markup
  changed, and nothing would say so.

  ## Examples

      <.attachment_img value={img.attachment} alt={img.alt} class="w-16 h-16" />
      <.attachment_img :for={i <- @images} value={i.attachment} states={@states} />
  """
  attr :value, :any, required: true, doc: "an `AshQuick.AshTypes.Attachment.Value` or nil"
  attr :states, :map, default: %{}, doc: "prefetched states from `AshQuick.Storage.states_for/1`"
  attr :class, :any, default: nil
  attr :alt, :any, default: ""
  attr :rest, :global

  def attachment_img(%{value: nil} = assigns) do
    ~H"""
    <span></span>
    """
  end

  def attachment_img(assigns) do
    assigns =
      assign(
        assigns,
        :resolution,
        AshQuick.Storage.url_for(assigns.value, states: assigns.states)
      )

    ~H"""
    <img
      :if={match?({:ok, _}, @resolution)}
      src={elem(@resolution, 1)}
      alt={@alt}
      class={@class}
      {@rest}
    />
    <span
      :if={@resolution == :processing}
      data-attachment-key={@value.key}
      data-attachment-placeholder-class={processing_placeholder_class()}
      class={[@class, "inline-flex items-center justify-center", processing_placeholder_class()]}
      title={gettext("This file is still being processed")}
    >
      {gettext("Processing")}
    </span>
    <span
      :if={@resolution == :rejected}
      class={[@class, "inline-flex items-center justify-center bg-error/10 text-error text-xs"]}
      title={gettext("This file was refused")}
    >
      {gettext("Rejected")}
    </span>
    """
  end

  # Published on the placeholder itself, so a host that draws over it takes off
  # exactly what this put on.
  defp processing_placeholder_class, do: "bg-base-200 text-base-content/50 text-xs"

  ## Label

  @doc """
  Renders a form label.
  """
  attr :for, :string, default: nil
  slot :inner_block, required: true

  def label(assigns) do
    ~H"""
    <label for={@for} class="label text-sm font-medium">
      {render_slot(@inner_block)}
    </label>
    """
  end

  ## Error

  @doc """
  Renders an error message.
  """
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class={["mt-1 flex gap-2 text-sm text-error", @class]}>
      <.icon name="hero-exclamation-circle-mini" class="mt-0.5 h-5 w-5 flex-none" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  ## Button

  @doc """
  Renders a button.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" class="ms-2">Send!</.button>
  """
  attr :type, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(disabled form name value)

  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "btn btn-primary btn-sm",
        "phx-submit-loading:opacity-75",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  ## Header

  @doc """
  Renders a header with title.
  """
  attr :class, :string, default: nil

  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[
      @actions != [] && "flex items-center justify-between gap-6 p-5",
      @class
    ]}>
      <div>
        <h1 class="text-lg font-semibold leading-8 text-base-content">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-2 text-sm leading-6 text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  ## Simple Form

  @doc """
  Renders a simple form.

  ## Examples

      <.simple_form for={@form} phx-change="validate" phx-submit="save">
        <.input field={@form[:email]} label="Email"/>
        <:actions>
          <.button>Save</.button>
        </:actions>
      </.simple_form>
  """
  attr :for, :any, required: true, doc: "the datastructure for the form"
  attr :as, :any, default: nil, doc: "the server side parameter to collect all input under"

  attr :rest, :global,
    include: ~w(autocomplete name rel action enctype method novalidate target multipart),
    doc: "the arbitrary HTML attributes to apply to the form tag"

  attr :form_title, :string, default: nil

  slot :inner_block, required: true
  slot :actions, doc: "the slot for form actions, such as a submit button"
  attr :submit_label, :string, default: nil, doc: "Submit button label"

  def simple_form(assigns) do
    ~H"""
    <section>
      <div class="py-8 px-4 mx-auto max-w-2xl md:max-w-screen-xl lg:py-16">
        <h2 :if={@form_title} class="mb-4 text-xl font-bold text-base-content">
          {@form_title}
        </h2>
        <.form :let={f} for={@for} as={@as} {@rest}>
          <div class="grid gap-4 sm:grid-cols-2 sm:gap-6">
            {render_slot(@inner_block, f)}
          </div>

          <button
            type="submit"
            class="btn btn-primary mt-4 sm:mt-6 phx-submit-loading:opacity-75"
          >
            {@submit_label || gettext("Save")}
          </button>
          {render_slot(@actions)}
        </.form>
      </div>
    </section>
    """
  end

  ## Input

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag
    * `type="checkbox"` is used exclusively to render boolean values

  ## Examples

      <.input field={@form[:email]} type="email" />
      <.input name="my-input" errors={["oh no!"]} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file hidden month number password
               range radio search select tel text textarea time url week)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  slot :inner_block

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox", value: value} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn -> Phoenix.HTML.Form.normalize_value("checkbox", value) end)

    ~H"""
    <div>
      <label class="flex items-center gap-4 text-sm leading-6 cursor-pointer">
        <input type="hidden" name={@name} value="false" />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class="checkbox checkbox-primary checkbox-sm"
          {@rest}
        />
        {@label}
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="sm:col-span-2">
      <.label for={@id}>{@label}</.label>
      <span :if={@rest[:required]} class="text-error"> &ast;</span>
      <select
        id={@id}
        name={@name}
        class={[
          "select w-full",
          @errors != [] && "select-error"
        ]}
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="sm:col-span-2">
      <.label for={@id}>{@label}</.label>
      <span :if={@rest[:required]} class="text-error"> &ast;</span>
      <textarea
        id={@id}
        name={@name}
        class={[
          "textarea w-full",
          @errors != [] && "textarea-error"
        ]}
        {@rest}
      ><%= Phoenix.HTML.Form.normalize_value("textarea", @value) %></textarea>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="sm:col-span-2">
      <.label for={@id}>{@label}</.label>
      <span :if={@rest[:required]} class="text-error"> &ast;</span>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[
          "input w-full",
          @errors != [] && "input-error"
        ]}
        {@rest}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  ## Error translation

  @doc """
  Translates an error message tuple into a human-readable string.

  By default, performs simple string interpolation (e.g. `{"should be at least %{count} characters", [count: 3]}`
  becomes `"should be at least 3 characters"`).

  For i18n support, configure a custom error translator:

      config :ash_quick,
        error_translator: {MyAppWeb.CoreComponents, :translate_error}
  """
  def translate_error({msg, opts}) do
    case AshQuick.Config.error_translator() do
      nil -> default_translate_error({msg, opts})
      {mod, fun} -> apply(mod, fun, [{msg, opts}])
    end
  end

  defp default_translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
