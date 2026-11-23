defmodule AshQuick.LiveView.Components.HasManyInput do
  @moduledoc false
  # A many-to-many argument picked as tags of records, through
  # `AshQuick.LiveView.FormRecords`.
  use Phoenix.LiveComponent
  import AshQuick.LiveView.Components.PickerInput

  require Logger

  alias AshQuick.LiveView.FormRecords
  alias AshQuick.LiveView.Utils

  # An option is worth the destination attribute the argument's items are
  # values of (`Utils.list_key/3`): the change's `value_is_key`, else the
  # primary key, which is what `manage_relationship` matches the submitted
  # list against. Unlike a belongs_to, `destination_attribute` here is the
  # foreign key pointing back at the source, so it is the wrong field to
  # identify a record by.
  #
  # A list of text whose change creates what matches nothing also offers the
  # typed text as a new value (`Utils.created_values/3`), when the actor may
  # run that create. Asked once, as the input mounts: it answers from the
  # scope alone, and the form redraws on every keystroke.
  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     assign_new(socket, :create, fn %{form: form, relationship: relationship} ->
       created_values(form, relationship, assigns.argument_name, assigns.scope)
     end)}
  end

  @impl true
  def render(assigns) do
    %{form: form, relationship: relationship, scope: scope} = assigns
    # Asked as the form draws, so a destination with no usable lookup action
    # fails here, naming the fix, rather than in the search behind the list.
    Utils.lookup_action!(relationship)
    key = Utils.list_key(argument(form, assigns.argument_name), relationship, action(form))
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
        create={@create != nil}
        create_match={if @create, do: @create.match, else: :exact}
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

  defp action(%Phoenix.HTML.Form{source: %{action: action}}), do: action

  defp argument(form, name) do
    form |> action() |> then(&Ash.Resource.Info.action(form.source.resource, &1)) |> arg(name)
  end

  defp arg(%{arguments: arguments}, name), do: Enum.find(arguments, &(&1.name == name))
  defp arg(_action, _name), do: nil

  # Asked as the create will run. `manage_relationship` runs it with none of
  # the form's own context but `:shared`, so no `action_source` either: a
  # policy reading one sees none there. A check Ash cannot settle before the
  # run offers the row, and the run decides: a refusal is then flashed, as
  # any other refused write is. A probe that fails is logged, and offers no
  # row.
  defp created_values(form, relationship, name, scope) do
    case Utils.created_values(argument(form, name), relationship, action(form)) do
      nil -> nil
      created -> if may_create?(relationship, created.action, scope), do: created
    end
  end

  defp may_create?(relationship, create, scope) do
    case Ash.can({relationship.destination, create}, scope,
           log_policy_breakdown?: false,
           maybe_is: true
         ) do
      {:ok, allowed} ->
        allowed in [true, :maybe]

      {:error, error} ->
        Logger.warning(fn ->
          "AshQuick could not ask whether #{inspect(relationship.destination)}." <>
            "#{create} may run for the form input of " <>
            "#{inspect(relationship.source)}.#{relationship.name}, which offers no " <>
            "new values:\n\n" <> Exception.message(Ash.Error.to_error_class(error))
        end)

        false
    end
  end
end
