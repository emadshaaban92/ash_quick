defmodule AshQuick.LiveView.Components.HasManyInput do
  @moduledoc false
  use Phoenix.LiveComponent
  import AshQuick.Components
  require Ash.Query

  alias AshQuick.LiveView.Utils

  @impl true
  def render(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns =
      assigns
      |> assign(:errors, Enum.map(field.errors, &translate_error(&1)))

    ~H"""
    <div phx-feedback-for={@field.name} class="sm:col-span-2">
      <.label for={@field.id}>{@label}</.label>
      <span :if={@required} class="text-error"> &ast;</span>
      <%!-- The tag class is replaced rather than extended: daisyUI 5's badge is a
      fixed-height box with inline padding only, so live_select's preset adds
      vertical padding the line has no room for and the text spills out. --%>
      <LiveSelect.live_select
        field={@field}
        style={:daisyui}
        container_extra_class="w-full"
        update_min_len={0}
        options={@default_options}
        allow_clear={true}
        mode={:quick_tags}
        tag_class="badge badge-primary h-auto min-h-6 py-0.5 max-w-full whitespace-normal"
        phx-target={@myself}
      />

      <.error :for={msg <- @errors} class="-mt-6">{msg}</.error>
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns) |> set_default_options() |> set_field()}
  end

  defp set_default_options(socket) do
    assign(
      socket,
      default_options: get_options(socket)
    )
  end

  defp set_field(socket) do
    %{form: form, argument_name: argument_name} = socket.assigns
    assign(socket, field: form[argument_name])
  end

  @impl true
  def handle_event(
        "live_select_change",
        %{"text" => search, "id" => live_select_id},
        socket
      ) do
    send_update(LiveSelect.Component,
      id: live_select_id,
      options: get_options(socket, search)
    )

    {:noreply, socket}
  end

  # An option is worth the destination's primary key, which is what
  # `manage_relationship` matches the submitted list against. Unlike a
  # belongs_to, `destination_attribute` here is the foreign key pointing back
  # at the source, so it is the wrong field to identify a record by.
  defp get_options(socket, search \\ nil) do
    %{form: form, relationship: relationship} = socket.assigns
    key = primary_key(relationship.destination)

    default_options =
      relationship.destination
      |> Ash.Query.for_read(
        Utils.lookup_action!(relationship),
        Utils.lookup_input(relationship.destination, search),
        scope: socket.assigns.scope
      )
      |> Utils.filter_inactive()
      |> maybe_add_relationship_filters(relationship.filters)
      |> Ash.Query.select(key)
      |> Utils.load_display_label()
      |> Ash.Query.page(count: false)
      |> Ash.read!()

    default_options_with_current =
      case Ash.Resource.loaded?(form.data, relationship.name) do
        true ->
          form.data
          |> Map.fetch!(relationship.name)
          |> List.wrap()
          |> Enum.concat(default_options.results)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq_by(&Map.fetch!(&1, key))

        false ->
          default_options.results
      end

    Enum.map(default_options_with_current, &{display_option(&1, key), Map.fetch!(&1, key)})
  end

  # An option value is one scalar, so a composite key has nothing to be
  # submitted as — better named here than as a wrong field silently picked.
  defp primary_key(resource) do
    case Ash.Resource.Info.primary_key(resource) do
      [key] ->
        key

      keys ->
        raise ArgumentError, """
        #{inspect(resource)} has the composite primary key #{inspect(keys)}, which \
        a multi-select has no single value to submit for. Relationships onto it \
        cannot be edited through a HasMany input.
        """
    end
  end

  defp maybe_add_relationship_filters(query, []), do: query

  defp maybe_add_relationship_filters(query, [%Ash.Resource.Dsl.Filter{filter: filter} | rest]) do
    query |> Ash.Query.filter(^filter) |> maybe_add_relationship_filters(rest)
  end

  # The key is what the option is submitted as, so showing it is the one
  # fallback that still points at the record the user picked.
  defp display_option(record, key) do
    AshQuick.Info.display_value(record) || to_string(Map.fetch!(record, key))
  end
end
