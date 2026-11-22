defmodule AshQuick.LiveView.Components.HasManyInput do
  @moduledoc false
  # A many-to-many argument picked as tags of records, through
  # `AshQuick.LiveView.FormRecords`.
  use Phoenix.LiveComponent
  import AshQuick.LiveView.Components.PickerInput

  alias AshQuick.LiveView.FormRecords

  # An option is worth the destination's primary key, which is what
  # `manage_relationship` matches the submitted list against. Unlike a
  # belongs_to, `destination_attribute` here is the foreign key pointing back
  # at the source, so it is the wrong field to identify a record by.
  @impl true
  def render(assigns) do
    %{form: form, relationship: relationship, scope: scope} = assigns
    # Asked as the form draws, so a destination with no usable lookup action
    # fails here, naming the fix, rather than in the search behind the list.
    AshQuick.LiveView.Utils.lookup_action!(relationship)
    key = primary_key(relationship.destination)
    current = current(form.data, relationship)

    assigns =
      assign(assigns,
        field: form[assigns.argument_name],
        search: &FormRecords.search(relationship, key, &1, scope, current),
        resolve: &FormRecords.resolve(relationship, key, &1, scope, current)
      )

    ~H"""
    <div phx-feedback-for={@field.name} class="sm:col-span-2 phx-submit-loading:pointer-events-none">
      <.picker_input
        field={@field}
        mode={:tags}
        search={@search}
        resolve={@resolve}
        label={@label}
        required={@required}
        help={assigns[:help]}
        records
      />
    </div>
    """
  end

  defp current(data, relationship) do
    if Ash.Resource.loaded?(data, relationship.name),
      do: data |> Map.fetch!(relationship.name) |> List.wrap(),
      else: []
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
end
