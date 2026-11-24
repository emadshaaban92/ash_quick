defmodule AshQuick.LiveView.Components.BelongsToInput do
  @moduledoc false
  # A belongs-to picked by its record, through `AshQuick.LiveView.FormRecords`.
  use Phoenix.LiveComponent
  import AshQuick.LiveView.Components.PickerInput

  alias AshQuick.LiveView.FormRecords

  # An option is worth exactly the field the foreign key points at, since that
  # is what the form writes back into `source_attribute`. Named rather than
  # assumed to be `:id`: `destination_attribute` is free to name another field,
  # and a primary key need not be called `:id` at all.
  @impl true
  def render(assigns) do
    %{form: form, relationship: relationship, scope: scope} = assigns
    # Asked as the form draws, so a destination with no usable lookup action
    # fails here, naming the fix, rather than in the search behind the list.
    AshQuick.LiveView.Utils.lookup_action!(relationship)
    key = relationship.destination_attribute
    current = current(form.data, relationship)
    narrowing = FormRecords.narrowing(assigns[:state_field])

    assigns =
      assign(assigns,
        narrowing: narrowing,
        field: form[relationship.source_attribute],
        search: &FormRecords.search(relationship, key, &1, scope, current, narrowing),
        resolve: &FormRecords.resolve(relationship, key, &1, scope, current, narrowing)
      )

    ~H"""
    <div phx-feedback-for={@field.name} class="sm:col-span-2 phx-submit-loading:pointer-events-none">
      <.picker_input
        field={@field}
        mode={:single}
        search={@search}
        resolve={@resolve}
        search_key={@narrowing}
        label={@label}
        required={@required}
        help={assigns[:help]}
        placeholder={assigns[:placeholder]}
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
end
