defmodule AshQuick.PubSub.Verifier do
  @moduledoc false
  # Refuses a `liveness quiet` entry that names no update action of the
  # resource. Only an update can change nothing, so any other name would be a
  # declaration with nothing to act on, and a misspelt one an action that goes
  # on refreshing every page for nothing.

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    updates =
      for %{type: :update, name: name} <- Verifier.get_entities(dsl_state, [:actions]),
          do: name

    case Verifier.get_option(dsl_state, [:ash_quick, :liveness], :quiet, []) --
           updates do
      [] ->
        :ok

      [name | _] ->
        {:error,
         Spark.Error.DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:ash_quick, :liveness, :quiet],
           message: """
           `quiet` names #{inspect(name)}, which is not an update action of \
           this resource. Only an update can change nothing, so only one belongs here.
           """
         )}
    end
  end
end
