defmodule AshQuick.LiveView.Components.FieldValue do
  @moduledoc false
  use Phoenix.Component
  use Gettext, backend: AshQuick.Gettext

  alias AshQuick.Labels
  alias AshQuick.LiveView.EnumOptions
  alias AshQuick.LiveView.QuickField

  attr :value, :any, required: true
  attr :path, :any, required: true
  attr :ash_field, :any, default: nil

  attr :scope, :any,
    default: nil,
    doc: "the page's request scope, which an attachment's state is read for"

  attr :viewer, :string,
    default: nil,
    doc:
      "an id for an attachment field's `AshQuick.Components.attachment_viewer/1`; none when nil"

  attr :viewer_label, :string,
    default: nil,
    doc: "that viewer's accessible name, as the page labels the field; the field's name when nil"

  attr :linker, :any,
    default: nil,
    doc:
      "a function from a record to its details path or `nil`, from `AshQuick.Nav.Info.details_linker/3`; a related record is plain text when nil"

  def field_value(%{value: nil} = assigns) do
    ~H"""
    <span></span>
    """
  end

  # What Ash leaves in a field a field policy hides from this actor. It is not
  # a value of the field's type, so no clause below can render it, and HEEx
  # refuses the struct itself. A mark rather than a blank, so a hidden value is
  # not mistaken for an empty one. Matched on the value alone, ahead of every
  # clause that reads `ash_field` or walks `path`.
  def field_value(%{value: %Ash.ForbiddenField{}} = assigns) do
    ~H"""
    <span class="text-base-content/50" title={gettext("Hidden")}>
      <span aria-hidden="true">—</span><span class="sr-only">{gettext("Hidden")}</span>
    </span>
    """
  end

  # A `sensitive?` field is redacted whatever it holds — a string, a date, a
  # number or a list of them — so it is asked before any clause that would
  # format the value.
  def field_value(%{path: [], ash_field: %{sensitive?: true}} = assigns) do
    ~H"""
    <span>{AshQuick.Info.mask(@value)}</span>
    """
  end

  def field_value(%{ash_field: %{type: AshQuick.AshTypes.Attachment}} = assigns) do
    assigns =
      assign(assigns, :states, AshQuick.Storage.states_for([assigns.value], scope: assigns.scope))

    ~H"""
    <AshQuick.Components.attachment_viewer
      :if={@viewer}
      id={@viewer}
      label={@viewer_label || Labels.name(@ash_field.name)}
      values={List.wrap(@value)}
      states={@states}
    />
    <.attachment_preview value={@value} states={@states} viewer={@viewer} />
    """
  end

  def field_value(%{ash_field: %{type: {:array, AshQuick.AshTypes.Attachment}}} = assigns) do
    assigns =
      assign(assigns, :states, AshQuick.Storage.states_for(assigns.value, scope: assigns.scope))

    ~H"""
    <AshQuick.Components.attachment_viewer
      :if={@viewer}
      id={@viewer}
      label={@viewer_label || Labels.name(@ash_field.name)}
      values={@value}
      states={@states}
    />
    <div class="flex flex-wrap gap-2">
      <.attachment_preview :for={value <- @value} value={value} states={@states} viewer={@viewer} />
    </div>
    """
  end

  # Whether the field holds a fixed set of values decides how its value reads,
  # and no guard can ask that, so it is asked once here, of the field the value
  # came from. A nested `field_value/1` is handed a field of its own and asks
  # again.
  def field_value(assigns) when not is_map_key(assigns, :choice) do
    assigns |> assign(:choice, EnumOptions.kind(assigns[:ash_field])) |> field_value()
  end

  # A value of a field with a fixed set reads as its label: an atom, or the
  # string a string-valued `Ash.Type.Enum` holds.
  def field_value(%{choice: choice, value: value} = assigns)
      when choice != nil and (is_atom(value) or is_binary(value)) do
    ~H"""
    <span>{EnumOptions.label(@ash_field, @value)}</span>
    """
  end

  # Each item is handed the list's field, so an item of a list of enum values
  # reads its label.
  def field_value(%{value: value} = assigns) when is_list(value) do
    ~H"""
    <span :for={{item, i} <- Enum.with_index(@value)}>
      <span :if={i != 0}> - </span>
      <.field_value
        value={item}
        path={@path}
        ash_field={@ash_field}
        scope={@scope}
        linker={@linker}
      />
    </span>
    """
  end

  # Read as an answer, the way the list's filter offers it, rather than as the
  # atom it is. Exports keep `true`/`false`: that is data, not the page.
  def field_value(%{value: value} = assigns) when is_boolean(value) do
    ~H"""
    <span>{if @value, do: gettext("Yes"), else: gettext("No")}</span>
    """
  end

  def field_value(%{value: value} = assigns) when is_atom(value) do
    ~H"""
    <span>{Labels.name(@value)}</span>
    """
  end

  def field_value(%{path: [path]} = assigns) do
    assigns = assigns |> assign(path: path)

    ~H"""
    <.field_value
      value={@value}
      path={@path}
      scope={@scope}
      viewer={@viewer}
      viewer_label={@viewer_label}
      linker={@linker}
    />
    """
  end

  def field_value(%{path: field_name} = assigns) when is_atom(field_name) do
    assigns =
      assigns
      |> assign(ash_field: Ash.Resource.Info.field(assigns.value, field_name))
      |> assign(value: Map.get(assigns.value, field_name))
      |> assign(path: [])

    ~H"""
    <.field_value
      value={@value}
      path={@path}
      ash_field={@ash_field}
      scope={@scope}
      viewer={@viewer}
      viewer_label={@viewer_label}
      linker={@linker}
    />
    """
  end

  def field_value(%{path: {relationship_name, rest}} = assigns)
      when is_atom(relationship_name) do
    relationship = Ash.Resource.Info.field(assigns.value, relationship_name)

    assigns =
      assigns
      |> assign(ash_field: relationship)
      |> assign(value: Map.get(assigns.value, relationship_name))
      |> assign(path: rest)
      |> assign(:links_label?, assigns.linker != nil and label_path?(relationship, rest))

    ~H"""
    <%= case {@links_label?, @value} do %>
      <% {true, [_ | _]} -> %>
        <span :for={{item, i} <- Enum.with_index(@value)}>
          <span :if={i != 0}> - </span>
          <.linked_label record={item} path={@path} scope={@scope} linker={@linker} />
        </span>
      <% {true, %_{}} -> %>
        <.linked_label record={@value} path={@path} scope={@scope} linker={@linker} />
      <% _ -> %>
        <.field_value
          value={@value}
          path={@path}
          ash_field={@ash_field}
          scope={@scope}
          viewer={@viewer}
          viewer_label={@viewer_label}
          linker={@linker}
        />
    <% end %>
    """
  end

  # Dates and times read the way `AshQuick.Config` formats them, the same as
  # an export writes them. Left to `Phoenix.HTML.Safe`, a `Date`, `Time` or
  # `NaiveDateTime` would print as ISO 8601 instead.
  def field_value(%{value: %DateTime{}} = assigns) do
    ~H"""
    <span>{AshQuick.Config.format_datetime(@value)}</span>
    """
  end

  def field_value(%{value: %NaiveDateTime{}} = assigns) do
    ~H"""
    <span>{AshQuick.Config.format_datetime(@value)}</span>
    """
  end

  def field_value(%{value: %Date{}} = assigns) do
    ~H"""
    <span>{AshQuick.Config.format_date(@value)}</span>
    """
  end

  def field_value(%{value: %Time{}} = assigns) do
    ~H"""
    <span>{AshQuick.Config.format_time(@value, format: :medium)}</span>
    """
  end

  # Left to `Phoenix.HTML.Safe`, a `Money` prints in Localize's own process
  # locale, which nothing sets, so every reader got English.
  def field_value(%{value: %{__struct__: Money}} = assigns) do
    ~H"""
    <span>{AshQuick.Config.format_money(@value)}</span>
    """
  end

  def field_value(%{ash_field: %{type: Ash.Type.Map}} = assigns) do
    ~H"""
    <pre>{Jason.encode!(@value, pretty: true)}</pre>
    """
  end

  def field_value(%{path: [], ash_field: %{type: AshQuick.AshTypes.Text}} = assigns) do
    ~H"""
    <p class="w-11/12 pe-4 overflow-x-auto text-wrap">{@value}</p>
    """
  end

  def field_value(%{path: [], value: %struct{}} = assigns) do
    assigns =
      assigns
      |> assign(:record_label, record_label(struct, assigns.value))
      |> assign(:record_path, record_path(struct, assigns.value, assigns.linker))

    ~H"""
    <.maybe_hinted_link
      navigate={@record_path}
      label={@record_label}
      hint={AshQuick.Info.display_hint_value(@value)}
    ><span>{@record_label || @value}</span></.maybe_hinted_link>
    """
  end

  def field_value(%{path: []} = assigns) do
    ~H"""
    <span>{@value}</span>
    """
  end

  @doc false
  # A link to a record's details page carrying its display hint, as a tooltip
  # and in its accessible name — the details header's writers and every
  # related record a details field names. The hint goes with the link: a
  # reader the record's page is not granted to sees the bare label.
  attr :navigate, :string, required: true
  attr :label, :string, required: true, doc: "what the link's accessible name starts with"
  attr :hint, :string, default: nil
  slot :inner_block, required: true

  def hinted_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="link"
      title={@hint}
      aria-label={@hint && label_with_hint(@label, @hint)}
    >{render_slot(@inner_block)}</.link>
    """
  end

  # `hinted_link/1` where there is a page to link to, and the content alone
  # where there is not.
  attr :navigate, :string, default: nil
  attr :label, :string, default: nil
  attr :hint, :string, default: nil
  slot :inner_block, required: true

  defp maybe_hinted_link(%{navigate: nil} = assigns), do: ~H"{render_slot(@inner_block)}"

  defp maybe_hinted_link(assigns) do
    ~H"""
    <.hinted_link navigate={@navigate} label={@label} hint={@hint}>{render_slot(@inner_block)}</.hinted_link>
    """
  end

  @doc false
  # A label with its hint beside it, worded by the locale: the link's
  # accessible name, and the impersonation banner's.
  def label_with_hint(label, nil), do: label
  def label_with_hint(label, hint), do: gettext("%{label} (%{hint})", label: label, hint: hint)

  # A related record named by its label field: the label renders through its
  # own field — formatted, masked or marked hidden as it would be anyway — and
  # is a link only when it can be read, since an unreadable one would leave
  # the link nothing to say.
  attr :record, :any, required: true
  attr :path, :any, required: true
  attr :scope, :any, default: nil
  attr :linker, :any, required: true

  defp linked_label(assigns) do
    label = AshQuick.Info.display_value(assigns.record)

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:navigate, label && assigns.linker.(assigns.record))

    ~H"""
    <.maybe_hinted_link
      navigate={@navigate}
      label={@label}
      hint={AshQuick.Info.display_hint_value(@record)}
    ><.field_value value={@record} path={@path} scope={@scope} /></.maybe_hinted_link>
    """
  end

  # Only on a label that can be read: the id `record_label/2` falls back to
  # is not something to send a reader to a page by.
  defp record_path(_struct, _value, nil), do: nil

  defp record_path(struct, value, linker) do
    if labelled_resource?(struct) and AshQuick.Info.display_value(value) != nil,
      do: linker.(value)
  end

  # A path from a relationship to the destination's display label names the
  # record as surely as stopping at the relationship does, and is how a page
  # gives that field a label of its own: `{[brand: :name], label: "Maker"}`
  # links the brand. The bare relationship is the clause above's, reached
  # with an empty path.
  defp label_path?(%{destination: destination}, rest) when rest not in [nil, []],
    do: QuickField.names_record?(destination, rest)

  defp label_path?(_relationship, _rest), do: false

  defp labelled_resource?(struct) do
    Ash.Resource.Info.resource?(struct) and not Ash.Resource.Info.embedded?(struct) and
      AshQuick in Spark.extensions(struct)
  end

  # A field path that stops at a relationship is a whole record, and what a
  # record is called is its resource's display label — the same answer the
  # dropdowns and the details header give. `nil` for anything else that reaches
  # here (a Money, an embedded address, an unloaded relationship), which renders
  # itself.
  #
  # A record never renders itself: `Phoenix.HTML.Safe` is not implemented for
  # one. So a record with neither a materialized label nor an `:id` — the
  # primary key does not have to be called that — still answers with something
  # renderable, rather than a `nil` the caller would read as "render the value"
  # and take the page down on.
  defp record_label(struct, value) do
    if Ash.Resource.Info.resource?(struct) and not Ash.Resource.Info.embedded?(struct) do
      AshQuick.Info.display_value(value) || Map.get(value, :id) || ""
    end
  end

  attr :value, :any, required: true
  attr :states, :map, default: %{}

  attr :viewer, :string,
    default: nil,
    doc: "the id of an `AshQuick.Components.attachment_viewer/1` a servable image opens"

  def attachment_preview(%{value: nil} = assigns) do
    ~H"""
    <span></span>
    """
  end

  # A video that is servable gets a player; everything else — images, and a
  # video the host is still holding — falls through to `attachment_img/1`,
  # which renders the placeholder.
  def attachment_preview(
        %{value: %AshQuick.AshTypes.Attachment.Value{file_type: :video}} = assigns
      ) do
    assigns =
      assign(
        assigns,
        :resolution,
        AshQuick.Storage.url_for(assigns.value, states: assigns.states)
      )

    ~H"""
    <video :if={match?({:ok, _}, @resolution)} class="max-w-36" controls preload="metadata">
      <source src={elem(@resolution, 1)} />
    </video>
    <AshQuick.Components.attachment_img
      :if={not match?({:ok, _}, @resolution)}
      value={@value}
      states={@states}
      class="max-w-36 px-3 py-2"
    />
    """
  end

  # A document has nothing to preview inline, so a servable one is a link to it.
  # Opened in a new tab rather than embedded: the host decides whether the
  # browser renders it or downloads it, through the object's own headers.
  def attachment_preview(
        %{value: %AshQuick.AshTypes.Attachment.Value{file_type: :document}} = assigns
      ) do
    assigns =
      assign(
        assigns,
        :resolution,
        AshQuick.Storage.url_for(assigns.value, states: assigns.states)
      )

    ~H"""
    <a
      :if={match?({:ok, _}, @resolution)}
      href={elem(@resolution, 1)}
      target="_blank"
      rel="noopener noreferrer"
      class="link inline-flex items-center gap-1 text-sm"
    >
      <AshQuick.Components.icon name="hero-document" class="w-4 h-4" />
      {AshQuick.AshTypes.Attachment.Value.display_name(@value)}
    </a>
    <AshQuick.Components.attachment_img
      :if={not match?({:ok, _}, @resolution)}
      value={@value}
      states={@states}
      class="max-w-36 px-3 py-2"
    />
    """
  end

  # Only a servable image has a slide in the viewer, so only it opens one.
  # The thumbnail is drawn from the URL resolved here, not resolved again by
  # `attachment_img/1`; the viewer resolves its slide's on its own.
  def attachment_preview(
        %{value: %AshQuick.AshTypes.Attachment.Value{file_type: :image}, viewer: viewer} =
          assigns
      )
      when is_binary(viewer) do
    assigns =
      assign(
        assigns,
        :resolution,
        AshQuick.Storage.url_for(assigns.value, states: assigns.states)
      )

    ~H"""
    <button
      :if={match?({:ok, _}, @resolution)}
      type="button"
      data-attachment-viewer={@viewer}
      data-attachment-view={@value.key}
      class="cursor-zoom-in transition hover:opacity-80"
      aria-label={
        gettext("View %{name}", name: AshQuick.AshTypes.Attachment.Value.display_name(@value))
      }
    >
      <img src={elem(@resolution, 1)} alt="" class="max-w-36" />
    </button>
    <AshQuick.Components.attachment_img
      :if={not match?({:ok, _}, @resolution)}
      value={@value}
      states={@states}
      class="max-w-36"
    />
    """
  end

  def attachment_preview(%{value: %AshQuick.AshTypes.Attachment.Value{}} = assigns) do
    ~H"""
    <AshQuick.Components.attachment_img value={@value} states={@states} class="max-w-36" />
    """
  end
end
