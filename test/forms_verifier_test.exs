defmodule AshQuick.FormsVerifierTest do
  @moduledoc """
  What `forms do full_page [...] end` will not let compile, and what it reads
  back.

  AshQuick opens only a public create, update or destroy, so a name that is
  anything else would leave the declaration doing nothing with no sign of why.

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

  defp probe(full_page) do
    name = "FormsProbe#{:erlang.unique_integer([:positive])}"

    source = """
    defmodule #{name} do
      use Ash.Resource,
        domain: AshQuick.FormsVerifierTest.Domain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshQuick]

      ash_quick do
        forms do
          full_page #{inspect(full_page)}
        end

        bookkeeping do
          inserted_at false
          updated_at false
          inserted_by false
          updated_by false
        end

        liveness do
          enabled? false
        end
      end

      attributes do
        uuid_primary_key :id
        attribute :name, :string, public?: true
      end

      actions do
        defaults [:read, :destroy, create: [:name], update: [:name]]

        update :internal do
          public? false
        end

        action :ping, :boolean do
          run fn _input, _context -> {:ok, true} end
        end
      end
    end
    """

    VerifierErrors.compile(source)
    Module.concat([name])
  end

  defp message(full_page) do
    assert [%Spark.Error.DslError{} = error] = VerifierErrors.errors(probe(full_page))
    Exception.message(error)
  end

  test "a public create, update and destroy compile, and are read back" do
    resource = probe([:create, :update, :destroy])

    assert VerifierErrors.errors(resource) == []
    assert AshQuick.Info.full_page?(resource, :create)
    assert AshQuick.Info.full_page?(resource, :update)
    assert AshQuick.Info.full_page?(resource, :destroy)
    refute AshQuick.Info.full_page?(resource, :read)
  end

  test "an action left out of the declaration opens in the modal" do
    resource = probe([])

    assert VerifierErrors.errors(resource) == []
    refute AshQuick.Info.full_page?(resource, :update)
  end

  test "an action the resource does not define does not compile" do
    assert message([:register]) =~ "names :register, which is no action of this resource"
  end

  test "a read does not compile" do
    assert message([:read]) =~ "names :read, a read action"
  end

  test "a generic action does not compile" do
    assert message([:ping]) =~ "names :ping, a generic action"
  end

  test "a private action does not compile" do
    assert message([:internal]) =~ "names :internal, which is private"
  end

  test "a resource without the extension declares nothing" do
    refute AshQuick.Info.full_page?(AshQuick.FormsVerifierTest.Domain, :create)
  end
end
