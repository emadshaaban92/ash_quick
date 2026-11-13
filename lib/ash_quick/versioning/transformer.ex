defmodule AshQuick.Versioning.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias AshQuick.Versioning.Declaration
  alias Ash.Resource.Dsl
  alias Ash.Resource.Info
  alias Spark.Dsl.Transformer

  # The attribute has to exist before anything reading the resource's fields
  # runs over it. The lock is the last of AshQuick's changes, after the audit
  # change and the actor stamps, so this runs after both transformers that
  # append them. Each of the three asks to run before everything, so without
  # the names here Spark leaves their order to chance.
  @runs_after [AshQuick.Audit.Transformer, AshQuick.Bookkeeping.Transformer]

  @impl true
  def after?(transformer) when transformer in @runs_after, do: true
  def after?(_), do: false

  @impl true
  def before?(transformer) when transformer in @runs_after, do: false
  def before?(_), do: true

  @impl true
  def transform(dsl_state) do
    if Declaration.enabled?(dsl_state) do
      attribute = Declaration.attribute(dsl_state)

      {:ok,
       dsl_state
       |> add_attribute_if_not_exists(attribute)
       |> keep_column_default(attribute)
       |> add_lock_change(attribute)}
    else
      {:ok, dsl_state}
    end
  end

  defp add_lock_change(dsl_state, attribute) do
    # Appended after the resource's own global changes, which Ash runs after
    # the action's, so on the atomic path the lock sees every value written.
    # In memory it decides in a `before_action` appended last, after every
    # other one has run. On a create it only acts on an upsert that meets a
    # row. See `AshQuick.Versioning.Lock`.
    {:ok, lock} =
      Transformer.build_entity(Dsl, [:changes], :change,
        change: {AshQuick.Versioning.Lock, [attribute: attribute]},
        on: [:create, :update, :destroy]
      )

    Transformer.add_entity(dsl_state, [:changes], lock, type: :append)
  end

  # The counter's default is a function (see
  # `AshQuick.Versioning.Declaration.initial/0`), which AshPostgres's
  # migration generator cannot read, so it would drop the column's `DEFAULT 1`.
  # Its `migration_defaults` says what the column holds instead, unless the
  # resource already said. Named rather than depended on: a host without
  # AshPostgres has no such section, and this does nothing.
  @migration_sections %{AshPostgres.DataLayer => [:postgres]}

  defp keep_column_default(dsl_state, name) do
    case Map.fetch(@migration_sections, Transformer.get_persisted(dsl_state, :data_layer)) do
      {:ok, section} ->
        defaults = Transformer.get_option(dsl_state, section, :migration_defaults) || []

        Transformer.set_option(
          dsl_state,
          section,
          :migration_defaults,
          Keyword.put_new(defaults, name, inspect(Declaration.initial()))
        )

      :error ->
        dsl_state
    end
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
