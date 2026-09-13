defmodule AshQuick.LiveView.Components.FieldValue do
  @moduledoc false
  use Phoenix.Component

  alias AshQuick.LiveView.Utils

  def field_value(%{value: nil} = assigns) do
    ~H"""
    <span></span>
    """
  end

  def field_value(%{ash_field: %{type: AshQuick.AshTypes.Attachment}} = assigns) do
    ~H"""
    <.attachment_preview value={@value} />
    """
  end

  def field_value(%{ash_field: %{type: {:array, AshQuick.AshTypes.Attachment}}} = assigns) do
    assigns = assign(assigns, :states, AshQuick.Storage.states_for(assigns.value))

    ~H"""
    <div class="flex flex-wrap gap-2">
      <.attachment_preview :for={value <- @value} value={value} states={@states} />
    </div>
    """
  end

  def field_value(%{value: value} = assigns) when is_list(value) do
    ~H"""
    <span :for={{item, i} <- Enum.with_index(@value)}>
      <span :if={i != 0}> - </span>
      <.field_value value={item} path={@path} />
    </span>
    """
  end

  def field_value(%{value: value} = assigns) when is_atom(value) do
    ~H"""
    <span>{@value |> Utils.humanize()}</span>
    """
  end

  def field_value(%{path: [path]} = assigns) do
    assigns = assigns |> assign(path: path)

    ~H"""
    <.field_value value={@value} path={@path} />
    """
  end

  def field_value(%{path: field_name} = assigns) when is_atom(field_name) do
    assigns =
      assigns
      |> assign(ash_field: Ash.Resource.Info.field(assigns.value, field_name))
      |> assign(value: Map.get(assigns.value, field_name))
      |> assign(path: [])

    ~H"""
    <.field_value value={@value} path={@path} ash_field={@ash_field} />
    """
  end

  def field_value(%{path: {relationship_name, rest}} = assigns)
      when is_atom(relationship_name) do
    assigns =
      assigns
      |> assign(ash_field: Ash.Resource.Info.field(assigns.value, relationship_name))
      |> assign(value: Map.get(assigns.value, relationship_name))
      |> assign(path: rest)

    ~H"""
    <.field_value value={@value} path={@path} ash_field={@ash_field} />
    """
  end

  def field_value(%{value: %DateTime{}} = assigns) do
    ~H"""
    <span>{AshQuick.Config.format_datetime(@value)}</span>
    """
  end

  def field_value(%{ash_field: %{type: Ash.Type.Map}} = assigns) do
    ~H"""
    <pre>{Jason.encode!(@value, pretty: true)}</pre>
    """
  end

  def field_value(%{path: [], ash_field: %{sensitive?: true}} = assigns)
      when is_binary(assigns.value) do
    ~H"""
    <span>{@value |> String.replace(Regex.compile!("."), "*")}</span>
    """
  end

  def field_value(%{path: [], ash_field: %{type: AshQuick.AshTypes.Text}} = assigns) do
    ~H"""
    <p class="w-11/12 pe-4 overflow-x-auto text-wrap">{@value}</p>
    """
  end

  def field_value(%{path: [], value: %struct{}} = assigns) do
    assigns = assign(assigns, :record_label, record_label(struct, assigns.value))

    ~H"""
    <span>{@record_label || @value}</span>
    """
  end

  def field_value(%{path: []} = assigns) do
    ~H"""
    <span>{@value}</span>
    """
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

  def attachment_preview(%{value: %AshQuick.AshTypes.Attachment.Value{}} = assigns) do
    ~H"""
    <AshQuick.Components.attachment_img value={@value} states={@states} class="max-w-36" />
    """
  end
end
