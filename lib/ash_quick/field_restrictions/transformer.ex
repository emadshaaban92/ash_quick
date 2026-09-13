defmodule AshQuick.FieldRestrictions.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias AshQuick.FieldRestrictions.Info

  @impl true
  def after?(Ash.Resource.Transformers.SetTypes), do: true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    restrictions = Info.field_restrictions(dsl_state)

    if Enum.empty?(restrictions) do
      {:ok, dsl_state}
    else
      {:ok, add_global_strip_change(dsl_state)}
    end
  end

  defp add_global_strip_change(dsl_state) do
    {:ok, change} =
      Spark.Dsl.Transformer.build_entity(
        Ash.Resource.Dsl,
        [:changes],
        :change,
        change: AshQuick.FieldRestrictions.StripRestrictedFields,
        on: [:create, :update]
      )

    Spark.Dsl.Transformer.add_entity(dsl_state, [:changes], change, type: :prepend)
  end
end
