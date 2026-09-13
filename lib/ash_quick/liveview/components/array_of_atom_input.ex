defmodule AshQuick.LiveView.Components.ArrayOfAtomInput do
  @moduledoc false
  alias AshQuick.LiveView.Utils
  use Phoenix.LiveComponent
  import AshQuick.Components

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

  defp get_options(socket, search \\ nil) do
    %{form: form, attribute: attribute} = socket.assigns

    default_options =
      attribute.constraints[:items][:one_of]
      |> Enum.filter(&String.starts_with?(to_string(&1), search || ""))

    case Ash.Resource.loaded?(form.data, attribute.name) do
      true ->
        form.data
        |> Map.fetch!(attribute.name)
        |> List.wrap()
        |> Enum.concat(default_options)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      false ->
        default_options
    end
    |> Enum.map(&{&1 |> Utils.humanize(), &1})
  end
end
