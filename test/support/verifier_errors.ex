defmodule AshQuick.Test.VerifierErrors do
  @moduledoc """
  The errors a resource's verifiers would have raised, as data.

  Verifiers run in `@after_verify`, which the compiler executes in its own
  checker process, so a verifier's error is reported there and never reaches
  `Code.compile_string/1`. `Spark.Test` collects errors through a pid in the
  *calling* process's dictionary, which that checker process cannot see: its
  do-block forms, wrapped around a module definition, collect nothing and pass.

  `__verify_spark_dsl__/1` is the hook the compiler calls, so calling it inside
  `Spark.Test.dsl_errors/1` runs the identical verifier list against the
  identical DSL state, in the process that collects.
  """
  require Spark.Test

  @doc "The verifier errors for `module`, `[]` when it compiles cleanly."
  def errors(module) do
    case Spark.Test.dsl_errors(do: module.__verify_spark_dsl__(module)) do
      [] -> []
      [{^module, errors}] -> errors
    end
  end
end
