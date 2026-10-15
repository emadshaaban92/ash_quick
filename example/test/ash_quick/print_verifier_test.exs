defmodule AshQuick.PrintVerifierTest do
  @moduledoc """
  An action carrying `AshQuick.Print` does not compile in a host without
  ChromicPDF.

  This app leaves `chromic_pdf` out on purpose (see `mix.exs`), which makes it
  the one place that half of `AshQuick.Print.Verifier` can be pinned: the
  library's own suite always has ChromicPDF.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  test "a print without ChromicPDF does not compile" do
    refute AshQuick.Config.print_enabled?()

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

      actions do
        update :print do
          accept []
          change {AshQuick.Print, template: MyTemplate}
        end
      end
    end
    """

    capture_io(:stderr, fn -> Code.compile_string(source) end)
    module = Module.concat([name])

    Process.put({Spark.Dsl, :test_collector}, self())
    module.__verify_spark_dsl__(module)

    assert_received {Spark.Dsl, :verifier_errors, ^module, [%Spark.Error.DslError{} = error]}
    assert Exception.message(error) =~ ~s({:chromic_pdf, "~> 1.17"})
  end
end
