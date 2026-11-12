defmodule AshQuick.ReadOnlyFieldsVerifierTest do
  @moduledoc """
  What `read_only_fields` will not let compile: an entry that would keep
  nothing read-only, because no create, update or destroy it covers takes the
  field as input (a misspelt name, most often), or because its `on:` names
  something other than a create, update or destroy that takes it.

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

  defmodule Always do
    @moduledoc false
    @behaviour AshQuick.ReadOnlyFields.Check

    @impl true
    def match?(_context, _opts), do: true
  end

  # An extension whose transformer adds an update after the read-only
  # transformer has run, so the action carries no strip of its own.
  defmodule LateActionTransformer do
    @moduledoc false
    use Spark.Dsl.Transformer

    @impl true
    def after?(AshQuick.ReadOnlyFields.Transformer), do: true
    def after?(_), do: false

    @impl true
    def before?(Ash.Resource.Transformers.ValidationsAndChangesForType), do: true
    def before?(_), do: false

    @impl true
    def transform(dsl_state) do
      {:ok, change} =
        Spark.Dsl.Transformer.build_entity(Ash.Resource.Dsl, [:actions, :update], :change,
          change: {Ash.Resource.Change.SetAttribute, attribute: :name, value: {:_arg, :label}}
        )

      {:ok, argument} =
        Spark.Dsl.Transformer.build_entity(Ash.Resource.Dsl, [:actions, :update], :argument,
          name: :label,
          type: :string
        )

      {:ok, action} =
        Spark.Dsl.Transformer.build_entity(Ash.Resource.Dsl, [:actions], :update,
          name: :late_relabel,
          accept: []
        )

      action = %{action | arguments: [argument], changes: [change]}
      {:ok, Spark.Dsl.Transformer.add_entity(dsl_state, [:actions], action)}
    end
  end

  defmodule LateAction do
    @moduledoc false
    use Spark.Dsl.Extension, transformers: [LateActionTransformer]
  end

  defp probe(entry, extensions \\ []) do
    name = "ReadOnlyProbe#{:erlang.unique_integer([:positive])}"

    source = """
    defmodule #{name} do
      use Ash.Resource,
        domain: AshQuick.ReadOnlyFieldsVerifierTest.Domain,
        data_layer: Ash.DataLayer.Ets,
        extensions: #{inspect([AshQuick | extensions])}

      ash_quick do
        read_only_fields do
          #{entry}
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
        attribute :secret, :string, public?: true
      end

      actions do
        defaults [:read, :destroy, create: [:name], update: [:name]]

        update :relabel do
          argument :label, :string
          change set_attribute(:name, arg(:label))
        end

        destroy :archive do
          soft? true
          accept [:name]
        end

        update :internal_relabel do
          argument :hidden_label, :string, public?: false
          change set_attribute(:name, arg(:hidden_label))
        end
      end
    end
    """

    VerifierErrors.compile(source)
    Module.concat([name])
  end

  defp message(entry, extensions \\ []) do
    assert [%Spark.Error.DslError{} = error] = VerifierErrors.errors(probe(entry, extensions))
    Exception.message(error)
  end

  @check "writable_if: AshQuick.ReadOnlyFieldsVerifierTest.Always"

  test "an accepted attribute and an action's argument compile" do
    assert VerifierErrors.errors(probe("read_only :name, #{@check}")) == []
    assert VerifierErrors.errors(probe("read_only :label, #{@check}")) == []

    assert VerifierErrors.errors(probe("read_only :name, #{@check}, on: [:create, :update]")) ==
             []

    assert VerifierErrors.errors(probe("read_only :label, #{@check}, on: :relabel")) == []
  end

  test "a misspelt field does not compile" do
    assert message("read_only :nmae, #{@check}") =~
             "`read_only :nmae` names a field no create, update or destroy takes as input"
  end

  test "an attribute no action accepts does not compile" do
    assert message("read_only :secret, #{@check}") =~
             "`read_only :secret` names a field no create, update or destroy"
  end

  test "a private argument does not compile" do
    assert message("read_only :hidden_label, #{@check}") =~
             "`read_only :hidden_label` names a field no create, update or destroy"
  end

  test "an on: action the resource does not define does not compile" do
    assert message("read_only :name, #{@check}, on: [:udpate]") =~
             "is `on:` :udpate, which is no action of this resource"
  end

  test "an on: action that is not a create, update or destroy does not compile" do
    assert message("read_only :name, #{@check}, on: [:read]") =~
             "is `on:` :read, a read action"
  end

  test "an on: destroy that takes the field compiles; one that does not, does not" do
    assert VerifierErrors.errors(probe("read_only :name, #{@check}, on: [:archive]")) == []

    assert message("read_only :name, #{@check}, on: [:destroy]") =~
             "is `on:` :destroy, which takes no :name as input"
  end

  test "an on: action that does not take the field does not compile" do
    assert message("read_only :label, #{@check}, on: [:update]") =~
             "is `on:` :update, which takes no :label as input"
  end

  test "an action added after the strip whose own changes take the field does not compile" do
    assert message("read_only :label, #{@check}", [LateAction]) =~
             "`read_only :label` covers :late_relabel, which runs changes before AshQuick's read-only strip"
  end

  test "such an action left out with on: compiles" do
    assert VerifierErrors.errors(probe("read_only :label, #{@check}, on: :relabel", [LateAction])) ==
             []

    assert VerifierErrors.errors(probe("read_only :name, #{@check}", [LateAction])) == []
  end
end
