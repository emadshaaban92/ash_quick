defmodule AshQuick.Activation.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Ash.Resource.Change
  alias Ash.Resource.Dsl
  alias Ash.Resource.Info
  alias Spark.Dsl.Transformer

  # The attribute and the two actions have to exist before anything reading the
  # resource's fields or actions runs over them.
  @impl true
  def after?(_), do: false

  @impl true
  def before?(_), do: true

  @impl true
  def transform(dsl_state) do
    if get(dsl_state, :enabled?, false) do
      attribute = get(dsl_state, :attribute, :active)

      {:ok,
       dsl_state
       |> add_attribute_if_not_exists(attribute)
       |> add_action_if_not_exists(get(dsl_state, :activate_action, :activate), attribute, true)
       |> add_action_if_not_exists(
         get(dsl_state, :deactivate_action, :deactivate),
         attribute,
         false
       )}
    else
      {:ok, dsl_state}
    end
  end

  defp get(dsl_state, option, default) do
    Transformer.get_option(dsl_state, [:ash_quick, :activation], option, default)
  end

  # `allow_nil?` is left at its default: the column these resources already
  # carry is nullable, and narrowing it here would be a migration.
  defp add_attribute_if_not_exists(dsl_state, name) do
    if Info.attribute(dsl_state, name) do
      dsl_state
    else
      {:ok, attribute} =
        Transformer.build_entity(Dsl, [:attributes], :attribute,
          name: name,
          type: :boolean,
          default: true,
          public?: true,
          always_select?: true
        )

      Transformer.add_entity(dsl_state, [:attributes], attribute, type: :append)
    end
  end

  # Absent only. A resource writing its own `:deactivate` — one carrying extra
  # changes or its own publications — keeps the one it wrote.
  defp add_action_if_not_exists(dsl_state, name, attribute, value) do
    if Info.action(dsl_state, name) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: name,
          accept: [],
          require_atomic?: false,
          changes: [
            Transformer.build_entity!(Dsl, [:actions, :update], :change,
              change: {Change.SetAttribute, [attribute: attribute, value: value]}
            )
          ]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end
end
