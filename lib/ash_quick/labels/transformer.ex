defmodule AshQuick.Labels.Transformer do
  @moduledoc false
  # Persists a resource's declared labels as one map, so drawing a label is a
  # lookup rather than a walk over its entities: `name => label` for a field,
  # action or argument, `{name, value} => label` for a value. Its declared help
  # texts likewise, as `name => text | false`.
  # `AshQuick.Labels.Verifier` checks them once the resource is whole.

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state) do
    entities = Transformer.get_entities(dsl_state, [:ash_quick, :labels])

    labels =
      for %AshQuick.Labels.Label{name: name, value: value, label: label} <- entities,
          into: %{},
          do: if(is_nil(value), do: {name, label}, else: {{name, value}, label})

    help =
      for %AshQuick.Labels.Help{name: name, help: help} <- entities, into: %{}, do: {name, help}

    {:ok,
     dsl_state
     |> Transformer.persist(:ash_quick_labels, labels)
     |> Transformer.persist(:ash_quick_help, help)}
  end
end
