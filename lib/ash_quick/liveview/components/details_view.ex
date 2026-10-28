defmodule AshQuick.LiveView.Components.DetailsView do
  @moduledoc false
  use Phoenix.Component
  use Gettext, backend: AshQuick.Gettext
  import AshQuick.Components
  alias Phoenix.LiveView.JS

  import AshQuick.LiveView.Components.FieldValue

  alias AshQuick.LiveView.DetailsUtils
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

    # One per render, shared by the header and the fields, for every resource
    # the page can link: each one's base path is resolved once, and the access
    # control asked once — or not at all, when none of them has a page.
    assigns =
      assigns
      |> assign(:featured_actions, featured)
      |> assign(:overflow_actions, overflow)
      |> assign(
        :linker,
        assigns.resource
        |> linkable_resources(assigns.fields)
        |> AshQuick.Nav.Info.details_linker(assigns.scope)
      )

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
          <.bookkeeping_header record={@record} linker={@linker} />
        </:subtitle>
        <:actions>
          <div class="flex items-center gap-1">
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
          <div
            :for={{field, index} <- Enum.with_index(@fields)}
            data-field={QuickField.data_field(field)}
            class="flex gap-4 py-4 text-sm leading-6 sm:gap-8"
          >
            <dt class="w-1/4 flex-none text-base-content/60">
              {field.label}
            </dt>
            <dd class="w-3/4 text-base-content">
              <.render_field
                field={field}
                index={index}
                record={@record}
                scope={@scope}
                linker={@linker}
              />
            </dd>
          </div>
        </dl>
      </div>
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
  #
  # The writer is a link to their details page for a reader who may navigate
  # there, and the link carries their display hint as a tooltip and in its
  # accessible name: a label is short, and two writers can share one. The hint
  # goes with the link, so a reader the route is not granted to sees the bare
  # name, and a hint that is personal data is shown no further than the page
  # it describes.
  defp bookkeeping_header(%{record: %resource{} = record, linker: linker} = assigns) do
    halves = [
      {:created, AshQuick.Info.inserted_at_field(resource),
       AshQuick.Info.inserted_by_field(resource)},
      {:updated, AshQuick.Info.updated_at_field(resource),
       AshQuick.Info.updated_by_field(resource)}
    ]

    writers = Enum.map(halves, fn {_kind, _at, by} -> by && Map.get(record, by) end)
    paths = Enum.map(writers, linker)

    parts =
      halves
      |> Enum.zip(Enum.zip(writers, paths))
      |> Enum.map(fn {{kind, at, _by}, {writer, path}} ->
        half(kind, timestamp(record, at), actor(writer, path))
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.intersperse([" · "])
      |> Enum.concat()

    assigns = assign(assigns, :parts, parts)

    # One line, and the parts carry their own spacing: whitespace between tags
    # here would land in the sentence.
    ~H"""
    <span :if={@parts != []}><.bookkeeping_part :for={part <- @parts} part={part} /></span>
    """
  end

  defp bookkeeping_part(%{part: text} = assigns) when is_binary(text), do: ~H"{@part}"

  defp bookkeeping_part(%{part: %{path: nil}} = assigns), do: ~H"{@part.label}"

  defp bookkeeping_part(assigns),
    do: ~H"""
    <.hinted_link navigate={@part.path} label={@part.label} hint={@part.hint}>{@part.label}</.hinted_link>
    """

  # The writers' resource, when the header names any, and every resource a
  # details field names a record of.
  defp linkable_resources(resource, fields) do
    actors =
      case {AshQuick.Config.actor_resource(), AshQuick.Info.actor_fields(resource)} do
        {nil, _fields} -> []
        {_actor, []} -> []
        {actor, _fields} -> [actor]
      end

    related = resource |> DetailsUtils.linked_records(fields) |> Enum.map(&elem(&1, 1))

    actors ++ related
  end

  # The sentence is translated whole with a marker standing in for the writer,
  # then split around it, so the writer can be markup wherever the translation
  # put them.
  @actor_marker "\u{E000}"

  defp half(kind, at, actor) do
    case sentence(kind, actor && @actor_marker, at) do
      nil -> nil
      text when is_nil(actor) -> [text]
      text -> text |> String.split(@actor_marker) |> Enum.intersperse(actor)
    end
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

  # `AshQuick.Info.display_value/1` is total over what a hidden or unloaded relationship
  # leaves behind — `nil`, `Ash.NotLoaded`, `Ash.ForbiddenField` — so a reader
  # who cannot see the actor gets the half without a name rather than a crash,
  # and masks a `sensitive?` label, which the link's accessible name carries.
  defp actor(writer, path) do
    case AshQuick.Info.display_value(writer) do
      nil -> nil
      label -> %{label: label, hint: path && AshQuick.Info.display_hint_value(writer), path: path}
    end
  end

  defp render_field(%{field: %QuickField{widget: widget, path: path}, record: record} = assigns)
       when is_function(widget) do
    assigns = assigns |> assign(:value, QuickField.resolve_value(record, path))

    # A widget is written for the field's own type, so it is never handed the
    # mark Ash leaves in a field a policy hides: `field_value/1` renders that.
    case assigns.value do
      %Ash.ForbiddenField{} -> ~H"<.field_value value={@value} path={[]} scope={@scope} />"
      _ -> widget.(assigns)
    end
  end

  # An attachment field opens its images in a viewer of its own, named for
  # its position: a field can be listed twice, so its name is not unique.
  # The resource is in the name so it does not take a host's own id. The
  # viewer is announced by the field's label, as the page shows it.
  defp render_field(%{field: %QuickField{path: path}, record: %resource{} = record} = assigns) do
    assigns =
      assigns
      |> assign(:value, record)
      |> assign(:path, path)
      |> assign(
        :viewer,
        "#{Ash.Resource.Info.short_name(resource)}-attachment-viewer-#{assigns.index}"
      )

    ~H"""
    <.field_value
      value={@value}
      path={@path}
      scope={@scope}
      viewer={@viewer}
      viewer_label={@field.label}
      linker={@linker}
    />
    """
  end

  defp available_actions(%resource{} = record, scope) do
    resource
    |> Utils.record_actions()
    |> Utils.reject_redundant_activation(record)
    |> Stream.filter(&AshQuick.can?({record, &1}, scope, :ash_quick_details))
  end

  defp featured_action(assigns) do
    ~H"""
    <button
      phx-click={JS.push("row_action_click", value: %{id: @row.id, action_name: @action.name})}
      class={[
        "btn btn-sm",
        if(@action.type == :destroy, do: "btn-error", else: "btn-primary")
      ]}
    >
      {Utils.humanize(@action.name)}
    </button>
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
    ~H"""
    <.link phx-click={
      JS.push("row_action_click", value: %{id: @record.id, action_name: @action.name})
    }>
      {Utils.humanize(@action.name)}
    </.link>
    """
  end
end
