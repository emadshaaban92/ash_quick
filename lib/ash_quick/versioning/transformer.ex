defmodule AshQuick.Versioning.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias AshQuick.Versioning.Declaration
  alias Ash.Resource.Dsl
  alias Ash.Resource.Info
  alias Spark.Dsl.Transformer

  # The attribute has to exist before anything reading the resource's fields
  # runs over it.
  @impl true
  def after?(_), do: false

  @impl true
  def before?(_), do: true

  @impl true
  def transform(dsl_state) do
    if Declaration.enabled?(dsl_state) do
      attribute = Declaration.attribute(dsl_state)

      {:ok,
       dsl_state
       |> add_attribute_if_not_exists(attribute)
       |> add_lock_change(attribute)}
    else
      {:ok, dsl_state}
    end
  end

  defp add_lock_change(dsl_state, attribute) do
    # Appended after the resource's own global changes, which Ash runs after
    # the action's, so on the atomic path the lock sees every value written.
    # In memory it decides in a `before_action` appended last, after every
    # other one has run. See `AshQuick.Versioning.Lock`.
    {:ok, lock} =
      Transformer.build_entity(Dsl, [:changes], :change,
        change: {AshQuick.Versioning.Lock, [attribute: attribute]},
        on: [:update, :destroy]
      )

    Transformer.add_entity(dsl_state, [:changes], lock, type: :append)
  end

  defp add_attribute_if_not_exists(dsl_state, name) do
    if Info.attribute(dsl_state, name) do
      dsl_state
    else
      {:ok, attribute} =
        Transformer.build_entity(
          Dsl,
          [:attributes],
          :attribute,
          [name: name, public?: true] ++ Declaration.counter()
        )

      Transformer.add_entity(dsl_state, [:attributes], attribute, type: :append)
    end
  end
end
