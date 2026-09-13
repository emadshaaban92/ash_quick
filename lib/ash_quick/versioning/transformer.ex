defmodule AshQuick.Versioning.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias AshQuick.Versioning.Declaration
  alias Ash.Resource.Dsl
  alias Ash.Resource.Info
  alias Spark.Dsl.Transformer

  # The attribute has to exist before anything reading the resource's fields
  # runs over it. Activation is the one exception: it appends `:activate` and
  # `:deactivate`, and `force_non_atomic_updates/1` has to see them.
  @impl true
  def after?(AshQuick.Activation.Transformer), do: true
  def after?(_), do: false

  @impl true
  def before?(AshQuick.Activation.Transformer), do: false
  def before?(_), do: true

  @impl true
  def transform(dsl_state) do
    if Declaration.enabled?(dsl_state) do
      attribute = Declaration.attribute(dsl_state)

      {:ok,
       dsl_state
       |> add_attribute_if_not_exists(attribute)
       |> add_lock_change(attribute)
       |> force_non_atomic_updates()}
    else
      {:ok, dsl_state}
    end
  end

  defp add_lock_change(dsl_state, attribute) do
    # The lock decides whether to filter + bump in a `before_action` (appended
    # last) so it sees the FINAL changeset, after every other `before_action`
    # has run. See `AshQuick.Versioning.Lock`.
    {:ok, lock} =
      Transformer.build_entity(Dsl, [:changes], :change,
        change: {AshQuick.Versioning.Lock, [attribute: attribute]},
        on: [:update, :destroy]
      )

    Transformer.add_entity(dsl_state, [:changes], lock, type: :append)
  end

  # The lock's decision needs the in-memory final changeset, which only exists on
  # the non-atomic path. Force every update/destroy action non-atomic so the
  # lock's `before_action` always runs — otherwise an atomic action would run
  # with no lock at all.
  defp force_non_atomic_updates(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:actions])
    |> Enum.reduce(dsl_state, fn
      %{type: type, require_atomic?: true} = action, dsl when type in [:update, :destroy] ->
        Transformer.replace_entity(
          dsl,
          [:actions],
          %{action | require_atomic?: false},
          fn entity -> entity.type == type and entity.name == action.name end
        )

      _action, dsl ->
        dsl
    end)
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
