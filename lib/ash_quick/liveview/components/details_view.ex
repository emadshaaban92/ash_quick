defmodule AshQuick.LiveView.Components.DetailsView do
  @moduledoc false
  use Phoenix.Component
  use Gettext, backend: AshQuick.Gettext
  import AshQuick.Components
  alias Phoenix.LiveView.JS

  import AshQuick.LiveView.Components.FieldValue
  import AshQuick.LiveView.Components.PrintModal

  alias AshQuick.LiveView.Utils
  alias AshQuick.LiveView.QuickField
  alias AshQuick.LiveView.URLParams

  def details_view(%{record: nil} = assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col items-center justify-center p-5 bg-base-200">
      <div class="text-center">
        <div class="mb-4">
          <.icon
            name="hero-exclamation-circle"
            class="h-24 w-24 text-error mx-auto"
          />
        </div>
        <h1 class="text-5xl font-bold text-base-content mb-4">404</h1>
        <p class="text-xl text-base-content/70 mb-8">
          {gettext("The resource you're looking for could not be found.")}
        </p>
        <.link navigate="/" class="btn btn-primary">
          <.icon name="hero-arrow-left" class="w-5 h-5" /> {gettext("Go back home")}
        </.link>
      </div>
    </div>
    """
  end

  def details_view(assigns) do
    all_actions = available_actions(assigns.record, assigns.scope)
    featured_actions = assigns.options.details_featured_actions

    {featured, overflow} = Enum.split_with(all_actions, &(&1.name in featured_actions))

    assigns =
      assigns
      |> assign(:featured_actions, featured)
      |> assign(:overflow_actions, overflow)

    ~H"""
    <section class="bg-base-200 p-3 sm:p-5">
      <.header class="p-5">
        <.link
          patch={URLParams.full_path(@base_path, @params |> URLParams.to_list_params())}
          class="btn btn-ghost btn-sm btn-square"
        >
          <.icon name="hero-arrow-left" class="w-5 h-5" />
        </.link>
        {AshQuick.Info.display_value(@record) || Map.get(@record, :id)}
        <:subtitle>
          <.bookkeeping_header record={@record} />
        </:subtitle>
        <:actions>
          <div class="flex items-center gap-1">
            <.details_print_menu
              :if={@print_actions != []}
              print_actions={@print_actions}
            />
            <.featured_action
              :for={action <- @featured_actions}
              row={@record}
              resource={@resource}
              action={action}
            />
            <.overflow_actions_dropdown
              :if={@overflow_actions != []}
              record={@record}
              resource={@resource}
              actions={@overflow_actions}
            />
          </div>
        </:actions>
      </.header>

      <div class="card bg-base-100 shadow-md p-5 mt-2">
        <dl class="-my-4 divide-y divide-base-200">
          <div :for={field <- @fields} class="flex gap-4 py-4 text-sm leading-6 sm:gap-8">
            <dt class="w-1/4 flex-none text-base-content/60">
              {field.label}
            </dt>
            <dd class="w-3/4 text-base-content">
              <.render_field field={field} record={@record} />
            </dd>
          </div>
        </dl>
      </div>
      <.print_modal :if={AshQuick.Config.print_enabled?()} print_data={@print_data} />
    </section>
    """
  end

  # "Created by X on Y · Last updated by Z on W", from what the resource declared
  # under `bookkeeping` rather than from those four names — nothing here knows
  # which resource it is rendering.
  #
  # The two halves are independently absent and each degrades on its own: an
  # append-only resource records no last write, one nobody creates through has no
  # creator, and an actor the reader's policies hide leaves the timestamp
  # standing alone. A resource carrying none of the four renders nothing at all.
  defp bookkeeping_header(%{record: %resource{}} = assigns) do
    halves =
      [
        half(
          assigns.record,
          :created,
          AshQuick.Info.created_at_field(resource),
          AshQuick.Info.created_by_field(resource)
        ),
        half(
          assigns.record,
          :updated,
          AshQuick.Info.updated_at_field(resource),
          AshQuick.Info.updated_by_field(resource)
        )
      ]
      |> Enum.reject(&is_nil/1)

    assigns = assign(assigns, :halves, halves)

    ~H"""
    <span :if={@halves != []}>{Enum.join(@halves, " · ")}</span>
    """
  end

  defp half(record, kind, at_field, by_field) do
    sentence(kind, actor_label(record, by_field), timestamp(record, at_field))
  end

  # Every combination is a whole sentence rather than a label joined to "by" and
  # "on": those connectives take different word orders per language, so a
  # translator given the pieces cannot put them back together.
  defp sentence(_kind, nil, nil), do: nil
  defp sentence(:created, nil, at), do: gettext("Created on %{at}", at: at)
  defp sentence(:created, actor, nil), do: gettext("Created by %{actor}", actor: actor)

  defp sentence(:created, actor, at),
    do: gettext("Created by %{actor} on %{at}", actor: actor, at: at)

  defp sentence(:updated, nil, at), do: gettext("Last updated on %{at}", at: at)
  defp sentence(:updated, actor, nil), do: gettext("Last updated by %{actor}", actor: actor)

  defp sentence(:updated, actor, at),
    do: gettext("Last updated by %{actor} on %{at}", actor: actor, at: at)

  defp timestamp(_record, nil), do: nil

  defp timestamp(record, field) do
    case Map.get(record, field) do
      %DateTime{} = at -> AshQuick.Config.format_datetime(at)
      _ -> nil
    end
  end

  # `display_value/1` is total over what a hidden or unloaded relationship
  # leaves behind — `nil`, `Ash.NotLoaded`, `Ash.ForbiddenField` — so a reader
  # who cannot see the actor gets the half without a name rather than a crash.
  defp actor_label(_record, nil), do: nil
  defp actor_label(record, field), do: record |> Map.get(field) |> AshQuick.Info.display_value()

  defp render_field(%{field: %QuickField{widget: widget, path: path}, record: record} = assigns)
       when is_function(widget) do
    assigns = assigns |> assign(:value, resolve_value(record, path))
    widget.(assigns)
  end

  defp render_field(%{field: %QuickField{path: path}, record: record} = assigns) do
    assigns = assigns |> assign(:value, record) |> assign(:path, path)

    ~H"""
    <.field_value value={@value} path={@path} />
    """
  end

  defp resolve_value(record, path) when is_atom(path), do: Map.get(record, path)

  defp resolve_value(record, [{relationship, nested}]) do
    record |> Map.get(relationship) |> resolve_value(nested)
  end

  defp resolve_value(nil, _path), do: nil

  defp available_actions(record, scope) do
    all_actions = Ash.Resource.Info.actions(record)

    all_actions
    |> Stream.filter(&(&1.type == :update))
    |> Utils.reject_redundant_activation(record)
    |> Stream.concat(all_actions |> Enum.filter(&(&1.type == :destroy)))
    |> Stream.filter(&AshQuick.can?({record, &1}, scope, :ash_quick_details))
  end

  defp featured_action(assigns) do
    data_confirm = action_data_confirm(assigns.resource, assigns.action.name)
    assigns = assigns |> assign(data_confirm: data_confirm)

    ~H"""
    <button
      phx-click={JS.push("row_action_click", value: %{id: @row.id, action_name: @action.name})}
      data-confirm={@data_confirm}
      class={[
        "btn btn-sm",
        if(@action.type == :destroy, do: "btn-error", else: "btn-primary")
      ]}
    >
      {Utils.humanize(@action.name)}
    </button>
    """
  end

  defp details_print_menu(assigns) do
    ~H"""
    <div class="dropdown dropdown-end">
      <div tabindex="0" role="button" class="btn btn-outline btn-sm">
        <.icon name="hero-printer" class="w-4 h-4" /> {gettext("Print")}
      </div>
      <ul
        tabindex="0"
        class="dropdown-content menu bg-base-300 rounded-box z-10 w-48 p-2 shadow-[0_2px_15px_rgba(0,0,0,0.3)] border border-base-content/10"
      >
        <li :for={action <- @print_actions}>
          <.link phx-click={action.func}>
            {action.title}
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  defp overflow_actions_dropdown(assigns) do
    ~H"""
    <div id="details-more-actions-dropdown" class="dropdown dropdown-end">
      <div tabindex="0" role="button" class="btn btn-outline btn-sm btn-square">
        <.icon name="hero-ellipsis-vertical" class="w-5 h-5" />
      </div>
      <ul
        tabindex="0"
        class="dropdown-content menu bg-base-300 rounded-box z-10 w-48 p-2 shadow-[0_2px_15px_rgba(0,0,0,0.3)] border border-base-content/10"
      >
        <li :for={action <- @actions}>
          <.overflow_action_item record={@record} resource={@resource} action={action} />
        </li>
      </ul>
    </div>
    """
  end

  defp overflow_action_item(assigns) do
    data_confirm = action_data_confirm(assigns.resource, assigns.action.name)
    assigns = assigns |> assign(data_confirm: data_confirm)

    ~H"""
    <.link
      phx-click={JS.push("row_action_click", value: %{id: @record.id, action_name: @action.name})}
      data-confirm={@data_confirm}
    >
      {Utils.humanize(@action.name)}
    </.link>
    """
  end

  defp action_data_confirm(resource, action_name) do
    resource
    |> Ash.Resource.Info.action_inputs(action_name)
    |> Enum.to_list()
    |> case do
      [] -> gettext("Are you sure?")
      _ -> nil
    end
  end
end
