defmodule AshQuick.VerifyTest do
  @moduledoc """
  A declaration an AshQuick verifier refuses fails the compile: it raises from
  the module's `@after_compile` callback rather than being reported as a
  warning, whatever flags the host compiles with.

  Each probe compiles outside the collector `AshQuick.Test.VerifierErrors`
  sets, so the error reaches `Code.compile_string/1` the way it reaches
  `mix compile`.
  """
  use ExUnit.Case, async: true

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defp resource(ash_quick) do
    name = "VerifyProbe#{:erlang.unique_integer([:positive])}"

    {name,
     """
     defmodule #{name} do
       use Ash.Resource,
         domain: AshQuick.VerifyTest.Domain,
         data_layer: Ash.DataLayer.Ets,
         extensions: [AshQuick]

       ash_quick do
         #{ash_quick}

         bookkeeping do
           inserted_at false
           updated_at false
           inserted_by false
           updated_by false
         end
       end

       attributes do
         uuid_primary_key :id
         attribute :name, :string, public?: true
       end

       actions do
         defaults [:read, :destroy, create: [:name], update: [:name]]
       end
     end
     """}
  end

  # How compiling `source` ended: `:ok`, or the exception it raised.
  defp compile(source) do
    Code.compile_string(source)
    :ok
  rescue
    exception -> exception
  end

  test "a resource an AshQuick verifier refuses does not compile" do
    {name, source} = resource("liveness do\n quiet [:nope]\n end")

    assert %Spark.Error.DslError{} = error = compile(source)
    assert Exception.message(error) =~ "[#{name}]"
    assert Exception.message(error) =~ "`quiet` names :nope"
  end

  test "every refusal of one resource is raised at once" do
    {_name, source} =
      resource("liveness do\n quiet [:nope]\n end\n forms do\n full_page [:missing]\n end")

    assert %Spark.Error.DslError{} = error = compile(source)
    message = Exception.message(error)

    assert message =~ "Multiple Errors Occurred"
    assert message =~ "`quiet` names :nope"
    assert message =~ "`full_page` names :missing"
  end

  test "a resource the verifiers accept compiles" do
    {_name, source} = resource("liveness do\n quiet [:update]\n end")

    assert compile(source) == :ok
  end

  test "a nav an AshQuick verifier refuses does not compile" do
    name = "VerifyNavProbe#{:erlang.unique_integer([:positive])}"

    source = """
    defmodule #{name} do
      use AshQuick.Nav

      nav do
        entry "products"
      end
    end
    """

    assert %Spark.Error.DslError{} = error = compile(source)
    assert Exception.message(error) =~ "do not start with a slash"
  end

  test "no AshQuick verifier is left to Spark, which would only warn" do
    for extension <- [AshQuick, AshQuick.Nav.Dsl] do
      assert Enum.filter(extension.verifiers(), &String.starts_with?(inspect(&1), "AshQuick.")) ==
               []
    end
  end

  test "every verifier AshQuick defines is run" do
    # A verifier missing from the map would never run at all, since Spark no
    # longer runs any of them.
    {:ok, modules} = :application.get_key(:ash_quick, :modules)

    defined =
      for module <- modules,
          Code.ensure_loaded?(module),
          Spark.Dsl.Verifier in behaviours(module),
          do: module

    registered = AshQuick.Verify.verifiers() |> Map.values() |> List.flatten()

    assert length(defined) == 12
    assert Enum.sort(defined) == Enum.sort(registered)
  end

  defp behaviours(module) do
    module.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
  end
end
