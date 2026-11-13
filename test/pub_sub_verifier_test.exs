defmodule AshQuick.PubSubVerifierTest do
  @moduledoc """
  What `liveness do quiet [...] end` will not let compile, and what
  it reads back.

  Only an update can change nothing, so any other name would be a declaration
  with nothing to act on, and a misspelt one an action that quietly stops
  refreshing pages.

  Each probe is compiled through `AshQuick.Test.VerifierErrors`. `async: false`
  because suppressing the compiler's own report means swapping the global
  `:standard_error` device.
  """
  use ExUnit.Case, async: false

  alias AshQuick.Test.VerifierErrors

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defp probe(quiet) do
    name = "PubSubProbe#{:erlang.unique_integer([:positive])}"

    source = """
    defmodule #{name} do
      use Ash.Resource,
        domain: AshQuick.PubSubVerifierTest.Domain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshQuick]

      ash_quick do
        liveness do
          quiet #{inspect(quiet)}
        end

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

        update :tally do
          accept []
        end
      end
    end
    """

    VerifierErrors.compile(source)
    Module.concat([name])
  end

  defp message(quiet) do
    assert [%Spark.Error.DslError{} = error] = VerifierErrors.errors(probe(quiet))
    Exception.message(error)
  end

  test "update actions compile, and are read back" do
    resource = probe([:update, :tally])

    assert VerifierErrors.errors(resource) == []
    assert AshQuick.Info.quiet(resource) == [:update, :tally]
  end

  test "a resource that names none reads back none" do
    resource = probe([])

    assert VerifierErrors.errors(resource) == []
    assert AshQuick.Info.quiet(resource) == []
  end

  test "an action the resource does not define does not compile" do
    assert message([:talley]) =~ "names :talley, which is not an update action"
  end

  test "a create or destroy does not compile" do
    assert message([:create]) =~ "names :create, which is not an update action"
    assert message([:destroy]) =~ "names :destroy, which is not an update action"
  end
end
