defmodule AshQuick.Verify do
  @moduledoc false
  # Runs AshQuick's verifiers so that an error in one fails the build.
  #
  # Spark runs a DSL's verifiers in `@after_verify` and turns each error they
  # return, and anything raised there, into a compile warning
  # (`Spark.Dsl.__verify_spark_dsl__/6`), so a misdeclared resource would
  # compile unless the host builds with `--warnings-as-errors`. AshQuick's
  # verifiers are therefore not handed to Spark. `AshQuick.Verify.Transformer`
  # registers `verify/2` as the module's `@after_compile` callback instead, and
  # an exception raised there is a compile error in the module's file, the same
  # as one raised by a transformer.
  #
  # `@after_compile` runs once the module is loaded, so reading another module
  # there (the audit store, the actor resource) waits for that one to compile
  # without making it a compile-time dependency, and a module waiting on this
  # one is not held up. Ash's own verifiers stay in Spark's `@after_verify`.
  #
  # `AshQuick.Test.VerifierErrors` compiles a probe with a collector pid under
  # `{AshQuick.Verify, :collector}` in its process dictionary, the process the
  # callback runs in, and the errors are sent there instead of raised.

  alias Spark.Error.DslError

  @verifiers %{
    AshQuick => [
      AshQuick.Identity.Verifier,
      AshQuick.Versioning.Verifier,
      AshQuick.Bookkeeping.Verifier,
      AshQuick.Audit.Verifier,
      AshQuick.Impersonation.Verifier,
      AshQuick.Lookup.Verifier,
      AshQuick.Print.Verifier,
      AshQuick.Labels.Verifier,
      AshQuick.Forms.Verifier,
      AshQuick.ReadOnlyFields.Verifier,
      AshQuick.PubSub.Verifier
    ],
    AshQuick.Nav.Dsl => [AshQuick.Nav.Verifier]
  }

  @doc false
  # Each extension's verifiers, read by the test that no verifier is left out.
  def verifiers, do: @verifiers

  @doc false
  # The `@after_compile` callback: raises the module's errors, or sends them to
  # the collector it is compiled under.
  def verify(%Macro.Env{module: module}, _bytecode) do
    dsl_state = module.spark_dsl_config()

    errors =
      for extension <- Spark.extensions(module),
          verifier <- Map.get(@verifiers, extension, []),
          error <- run(verifier, dsl_state),
          uniq: true,
          do: error

    case Process.get({__MODULE__, :collector}) do
      pid when is_pid(pid) -> send(pid, {__MODULE__, :errors, module, errors})
      _ -> raise_errors(errors)
    end
  end

  defp run(verifier, dsl_state) do
    case verifier.verify(dsl_state) do
      :ok -> []
      {:error, errors} -> List.wrap(errors)
    end
  end

  defp raise_errors([]), do: :ok
  defp raise_errors([error]), do: raise(error)

  defp raise_errors(errors) do
    raise DslError,
      message:
        "Multiple Errors Occurred\n\n" <>
          Enum.map_join(errors, "\n---\n", &Exception.message/1)
  end
end

defmodule AshQuick.Verify.Transformer do
  @moduledoc false
  # Registers `AshQuick.Verify.verify/2` as the module's `@after_compile`
  # callback. See `AshQuick.Verify`.

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state) do
    {:ok, Transformer.eval(dsl_state, [], quote(do: @after_compile({AshQuick.Verify, :verify})))}
  end
end
