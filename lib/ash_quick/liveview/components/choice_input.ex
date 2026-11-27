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
    narrowed = narrowed(assigns[:state_field])
    offered = attribute |> EnumOptions.options(resource) |> offered(narrowed)
    # Under options a hook narrows, a stored value they leave out is not
    # offered again: it stays picked, under its label, and can be unpicked.
    stored = if narrowed, do: [], else: stored(form.data, attribute, resource)

    assigns =
      assign(assigns,
        narrowed: narrowed,
        field: form[attribute.name],
        search: fn text -> search(stored, offered, text) end,
        resolve: fn _values ->
          stored(form.data, attribute, resource) ++
            Enum.map(EnumOptions.options(attribute, resource), &option/1)
        end
      )

    ~H"""
    <div phx-feedback-for={@field.name} class="sm:col-span-2 phx-submit-loading:pointer-events-none">
      <.picker_input
        field={@field}
        mode={if @multiple, do: :tags, else: :single}
        search={@search}
        resolve={@resolve}
        search_key={@narrowed}
        label={@label}
        required={@required}
        help={assigns[:help]}
      />
    </div>
    """
  end

  # The values `adjust_form/2` narrowed the field to
  # (`AshQuick.FormState.options/3`), or nil for all its type lists.
  defp narrowed(%{options: options}) when is_list(options), do: options
  defp narrowed(_state_field), do: nil

  defp offered(options, nil), do: options

  defp offered(options, narrowed) do
    kept = MapSet.new(narrowed, &to_string/1)
    Enum.filter(options, fn {_label, value} -> MapSet.member?(kept, to_string(value)) end)
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
