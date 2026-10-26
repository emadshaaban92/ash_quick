defmodule AshQuick.Test.VerifierErrors do
  @moduledoc """
  The errors a resource's verifiers raised, as data.

  Verifiers run in `@after_verify`, which the compiler executes in its own
  checker process, so a verifier's error is reported there and never reaches
  `Code.compile_string/1`. Since spark 2.7.9 a DSL module captures the
  `Spark.Test` collector when it is compiled and reports to it from that
  checker process, so `compile/1` compiles inside `Spark.Test.dsl_errors/1` and
  keeps what each module reported for `errors/1` to read back.
  """
  require Spark.Test

  @doc """
  Compiles `source`, keeping its modules' verifier errors instead of letting
  the compiler print them.
  """
  def compile(source) do
    collected =
      Spark.Test.dsl_errors do
        for {module, _} <- Code.compile_string(source), do: Process.put({__MODULE__, module}, [])
      end

    Enum.each(collected, fn {module, errors} -> Process.put({__MODULE__, module}, errors) end)
  end

  @doc """
  The verifier errors `compile/1` kept for `module`, `[]` when it compiled
  cleanly. Raises for a module `compile/1` never compiled, so a probe that
  skipped it cannot pass for a clean one.
  """
  def errors(module) do
    case Process.get({__MODULE__, module}) do
      nil -> raise ArgumentError, "#{inspect(module)} was not compiled through compile/1"
      errors -> errors
    end
  end
end
