defmodule AshQuick.PrintVerifierTest do
  @moduledoc """
  What the print verifier will not let compile, and what it lets through.

  Ash calls a change's `init/1` only when the action runs, so without this a
  print that cannot work is found by the first person to click it. This app has
  ChromicPDF, so every probe here is about the action; the example app, which
  leaves ChromicPDF out, pins the other half.

  Probed the way `AshQuick.LookupVerifierTest` probes, through
  `AshQuick.Test.VerifierErrors`.
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

  defp verifier_errors(body) do
    name = "PrintProbe#{:erlang.unique_integer([:positive])}"

    source = """
    defmodule #{name} do
      use Ash.Resource,
        domain: AshQuick.PrintVerifierTest.Domain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshQuick]

      ash_quick do
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

      #{body}
    end
    """

    VerifierErrors.compile(source)
    VerifierErrors.errors(Module.concat([name]))
  end

  defp message(body) do
    assert [%Spark.Error.DslError{} = error] = verifier_errors(body)
    Exception.message(error)
  end

  test "a print on a create or an update compiles" do
    assert verifier_errors("""
           actions do
             create :register do
               change {AshQuick.Print, template: MyTemplate}
             end

             update :print do
               accept []
               change {AshQuick.Print, template: MyTemplate, delivery: :print}
             end
           end
           """) == []
  end

  test "a print on a destroy does not compile" do
    # `Ash.destroy/2` hands back `:ok`, so there is no record to mark.
    assert message("""
           actions do
             destroy :archive do
               change {AshQuick.Print, template: MyTemplate}
             end
           end
           """) =~ "on a destroy action it would never print"
  end

  test "a global print that runs on destroys does not compile" do
    assert message("""
           actions do
             defaults [:read, :destroy, create: :*]
           end

           changes do
             change {AshQuick.Print, template: MyTemplate}, on: [:create, :destroy]
           end
           """) =~ "on a destroy action it would never print"
  end

  test "a global print left to its default `on` compiles" do
    assert verifier_errors("""
           actions do
             defaults [:read, :destroy, create: :*]
           end

           changes do
             change {AshQuick.Print, template: MyTemplate}
           end
           """) == []
  end

  test "options the change would refuse at run time do not compile" do
    assert message("""
           actions do
             update :print do
               change {AshQuick.Print, template: MyTemplate, delivery: :fax}
             end
           end
           """) =~ "`delivery:` one of [:download, :print]"
  end
end
