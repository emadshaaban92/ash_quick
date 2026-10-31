defmodule AshQuick.Labels.Transformer do
  @moduledoc false
  # Persists a resource's declared labels as one map, so drawing a label is a
  # lookup rather than a walk over its entities: `name => label` for a field,
  # action or argument, `{name, value} => label` for a value.
  # `AshQuick.Labels.Verifier` checks them once the resource is whole.

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state) do
    labels =
      dsl_state
      |> Transformer.get_entities([:ash_quick, :labels])
      |> Map.new(fn
        %{name: name, value: nil, label: label} -> {name, label}
        %{name: name, value: value, label: label} -> {{name, value}, label}
      end)

    {:ok, Transformer.persist(dsl_state, :ash_quick_labels, labels)}
  end
end
