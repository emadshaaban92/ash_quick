defmodule AshQuick.LiveView.Components.ChoiceInput do
  @moduledoc false
  # A field picked from a fixed set (`AshQuick.LiveView.EnumOptions`): an
  # `Ash.Type.Enum`, or an atom with `one_of`. `multiple` picks a list of them.
  use Phoenix.LiveComponent
  import AshQuick.Components
  alias AshQuick.LiveView.EnumOptions

  @impl true
  def render(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns =
      assigns
      |> assign(:errors, AshQuick.LiveView.FieldErrors.for_select(field))

    ~H"""
    <div phx-feedback-for={@field.name} class="sm:col-span-2 phx-submit-loading:pointer-events-none">
      <.label for={@field.id}>{@label}</.label>
      <span :if={@required} class="text-error"> &ast;</span>
      <LiveSelect.live_select
        :if={not @multiple}
        field={@field}
        style={:daisyui}
        container_extra_class="w-full"
        update_min_len={0}
        allow_clear={true}
        options={@default_options}
        phx-target={@myself}
        phx-focus="set-default"
      />
      <%!-- The tag class is replaced rather than extended: daisyUI 5's badge is a
      fixed-height box with inline padding only, so live_select's preset adds
      vertical padding the line has no room for and the text spills out. --%>
      <LiveSelect.live_select
        :if={@multiple}
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

      <AshQuick.LiveView.FieldErrors.used_marker field={@field} />
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
    %{form: form, attribute: attribute} = socket.assigns
    assign(socket, field: form[attribute.name])
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

  @impl true
  def handle_event("set-default", %{"id" => live_select_id}, socket) do
    send_update(LiveSelect.Component,
      id: live_select_id,
      options: get_options(socket)
    )

    {:noreply, socket}
  end

  # The stored value leads, so a value the type no longer lists still shows
  # as picked; a search narrows only the values on offer.
  defp get_options(socket, search \\ nil) do
    %{form: form, attribute: attribute} = socket.assigns

    on_offer = attribute |> EnumOptions.options() |> EnumOptions.search(search)

    case Ash.Resource.loaded?(form.data, attribute.name) do
      true ->
        form.data
        |> Map.fetch!(attribute.name)
        |> List.wrap()
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&{EnumOptions.label(attribute, &1), &1})
        |> Enum.concat(on_offer)
        |> Enum.uniq_by(&elem(&1, 1))

      false ->
        on_offer
    end
  end
end
