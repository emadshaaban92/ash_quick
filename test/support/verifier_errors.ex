defmodule AshQuick.Test.VerifierErrors do
  @moduledoc """
  The errors a resource's verifiers raised, as data.

  AshQuick's verifiers raise from the module's `@after_compile` callback, which
  is what fails a host's build. `compile/1` puts the test process under
  `{AshQuick.Verify, :collector}` while it compiles, and `AshQuick.Verify`
  sends each module's errors to it instead of raising.

  Other extensions' verifiers (Ash's own) run in `@after_verify`, in the
  compiler's checker process, and Spark only reports their errors as warnings.
  Since spark 2.7.9 a DSL module captures the `Spark.Test` collector when it is
  compiled and reports to it from there, so `compile/1` also compiles inside
  `Spark.Test.dsl_errors/1`, and `errors/1` reads back both.
  """
  require Spark.Test

  @doc """
  Compiles `source`, keeping its modules' verifier errors instead of letting
  them fail the compile.
  """
  def compile(source) do
    previous = Process.put({AshQuick.Verify, :collector}, self())

    collected =
      try do
        Spark.Test.dsl_errors do
          for {module, _} <- Code.compile_string(source),
              do: Process.put({__MODULE__, module}, [])
        end
      after
        case previous do
          nil -> Process.delete({AshQuick.Verify, :collector})
          pid -> Process.put({AshQuick.Verify, :collector}, pid)
        end
      end

    Enum.each(collected ++ drain([]), fn {module, errors} ->
      Process.put({__MODULE__, module}, Process.get({__MODULE__, module}, []) ++ errors)
    end)
  end

  # `@after_compile` runs in the compiling process, so each report is in the
  # mailbox by the time `Code.compile_string/1` returns.
  defp drain(acc) do
    receive do
      {AshQuick.Verify, :errors, module, errors} -> drain([{module, errors} | acc])
    after
      0 -> Enum.reverse(acc)
    end
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
