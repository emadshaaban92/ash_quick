defmodule AshQuick.LabelsVerifierTest do
  @moduledoc """
  What a resource's `labels` will not let compile: a label naming nothing the
  resource has, one for a value its field does not offer, and a name or value
  labelled twice. A label naming nothing would leave the humanized name drawn
  with no sign of why.

  Probed the way `AshQuick.PrintVerifierTest` probes, through
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

  defp verifier_errors(labels) do
    name = "LabelsProbe#{:erlang.unique_integer([:positive])}"

    source = """
    defmodule #{name} do
      use Ash.Resource,
        domain: AshQuick.LabelsVerifierTest.Domain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshQuick]

      ash_quick do
        labels do
          #{labels}
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
        attribute :status, AshQuick.Test.Labels.Status, public?: true
        attribute :kind, :atom, public?: true, constraints: [one_of: [:personal, :business]]
        attribute :code, :atom, public?: true
      end

      calculations do
        calculate :shout, :string, expr(name <> "!"), public?: true
      end

      relationships do
        belongs_to :borrower, AshQuick.Test.Labels.Borrower, public?: true
      end

      actions do
        defaults [:read]

        update :settle do
          accept []
          require_atomic? false
          argument :settled_status, AshQuick.Test.Labels.Status
        end
      end
    end
    """

    VerifierErrors.compile(source)
    VerifierErrors.errors(Module.concat([name]))
  end

  defp message(labels) do
    assert [%Spark.Error.DslError{} = error] = verifier_errors(labels)
    Exception.message(error)
  end

  test "a label for a field, relationship, action, argument or offered value compiles" do
    assert verifier_errors("""
           label :name, "Loan Name"
           label :shout, "Loud Name"
           label :borrower, "Applicant"
           label :settle, "Settle in Full"
           label :settled_status, "Settled As"
           label :status, :paid_off, "Paid Off in Full"
           label :settled_status, :cancelled, "Written Off"
           label :kind, :business, "Business Loan"
           label :code, :anything, "Any Code"
           """) == []
  end

  test "a label naming nothing the resource has does not compile" do
    assert message(~s(label :borower, "Applicant")) =~
             "`label :borower` names no attribute, calculation, aggregate, relationship, action or action argument"
  end

  test "a value label on a name that is no field or argument does not compile" do
    assert message(~s(label :settle, :done, "Done")) =~
             "which is no attribute, calculation, aggregate or action argument"
  end

  test "a value its field does not offer does not compile" do
    message = message(~s(label :status, :closed, "Closed"))

    assert message =~ "labels a value :status does not offer"
    assert message =~ ":active, :paid_off, :cancelled"
  end

  test "a name or value labelled twice does not compile" do
    assert message("""
           label :name, "Loan Name"
           label :name, "Title"
           """) =~ "`:name` is labelled more than once"

    assert message("""
           label :kind, :business, "Business Loan"
           label :kind, :business, "Company Loan"
           """) =~ "Value :business of `:kind` is labelled more than once"
  end
end
