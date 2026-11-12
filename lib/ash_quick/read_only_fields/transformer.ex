defmodule AshQuick.ReadOnlyFields.Transformer do
  @moduledoc false
  # Puts the read-only strip first among the changes of every create, update
  # and destroy (a soft destroy can accept fields), so it drops a refused
  # input before any of the action's own changes can read it: a
  # `manage_relationship` over an argument, or a `set_attribute(:x, arg(:y))`.
  # A global change would come too late for those, since Ash runs an action's
  # changes before the global ones.
  #
  # The global change stays too: it undoes a read-only attribute an action's
  # own change wrote, and the input of an action another
  # extension adds after this transformer has run. Such an action has no strip
  # ahead of its own changes, so `AshQuick.ReadOnlyFields.Verifier` refuses one
  # that has changes and takes a read-only field.
  use Spark.Dsl.Transformer

  alias AshQuick.ReadOnlyFields.Info
  alias AshQuick.ReadOnlyFields.StripReadOnlyFields
  alias Spark.Dsl.Transformer

  @impl true
  def after?(Ash.Resource.Transformers.SetTypes), do: true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    if Enum.empty?(Info.read_only_fields(dsl_state)) do
      {:ok, dsl_state}
    else
      dsl_state
      |> strip_first_in_each_action()
      |> add_global_strip_change()
    end
  end

  defp strip_first_in_each_action(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:actions])
    |> Enum.filter(&(&1.type in [:create, :update, :destroy]))
    |> Enum.reduce(dsl_state, fn action, dsl_state ->
      {:ok, change} =
        Transformer.build_entity(Ash.Resource.Dsl, [:actions, action.type], :change,
          change: {StripReadOnlyFields, stage: :action}
        )

      Transformer.replace_entity(
        dsl_state,
        [:actions],
        %{action | changes: [change | action.changes]},
        &(&1.name == action.name)
      )
    end)
  end

  defp add_global_strip_change(dsl_state) do
    {:ok, change} =
      Transformer.build_entity(Ash.Resource.Dsl, [:changes], :change,
        change: {StripReadOnlyFields, stage: :global},
        on: [:create, :update, :destroy]
      )

    {:ok, Transformer.add_entity(dsl_state, [:changes], change, type: :prepend)}
  end
end
