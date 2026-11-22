defmodule AshQuick.LiveView.Components.ChoiceInput do
  @moduledoc false
  # A field picked from a fixed set (`AshQuick.LiveView.EnumOptions`): an
  # `Ash.Type.Enum`, or an atom with `one_of`. `multiple` picks a list of them.
  # `resource`, the form's, labels the values as it declares them.
  use Phoenix.LiveComponent
  import AshQuick.LiveView.Components.PickerInput
  alias AshQuick.LiveView.EnumOptions

  @impl true
  def render(assigns) do
    %{form: form, attribute: attribute} = assigns
    resource = assigns[:resource]
    stored = stored(form.data, attribute, resource)
    offered = EnumOptions.options(attribute, resource)

    assigns =
      assign(assigns,
        field: form[attribute.name],
        search: fn text -> search(stored, offered, text) end,
        resolve: fn _values -> stored ++ Enum.map(offered, &option/1) end
      )

    ~H"""
    <div phx-feedback-for={@field.name} class="sm:col-span-2 phx-submit-loading:pointer-events-none">
      <.picker_input
        field={@field}
        mode={if @multiple, do: :tags, else: :single}
        search={@search}
        resolve={@resolve}
        label={@label}
        required={@required}
        help={assigns[:help]}
      />
    </div>
    """
  end

  # The values the record holds lead the list when nothing is typed, so one
  # the type no longer lists can still be seen and unpicked; typing narrows
  # only the values on offer, by label.
  defp search(stored, offered, nil),
    do: Enum.uniq_by(stored ++ Enum.map(offered, &option/1), & &1.value)

  defp search(_stored, offered, text),
    do: offered |> EnumOptions.search(text) |> Enum.map(&option/1)

  defp stored(data, attribute, resource) do
    if Ash.Resource.loaded?(data, attribute.name) do
      data
      |> Map.fetch!(attribute.name)
      |> List.wrap()
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&option({EnumOptions.label(attribute, &1, resource), &1}))
    else
      []
    end
  end

  defp option({label, value}), do: %{value: to_string(value), label: label}
end
