defmodule AshQuick.VersioningVerifierTest do
  @moduledoc """
  A resource whose `:version` means something else must not compile.

  `AshQuick.Versioning.Transformer` adds the counter only when the resource does
  not already define an attribute by that name, so a resource that owns a
  `:version` for its own reasons keeps its own column and the lock quietly
  operates on it — filtering writes on a value it does not control and
  incrementing it on every save.

  This is not hypothetical: an outbox extension hands its event and delivery
  resources a `:version` holding the event's *schema* version. A host sweeps
  its own resources for that collision; what is pinned here is that the
  verifier reports it, so the build stops instead of the outbox quietly
  corrupting.

  Verifiers run in `@after_verify`, which the compiler executes in its own
  checker process — so the error is reported there and never propagates out of
  `Code.compile_string/1` for a test to catch. `__verify_spark_dsl__/1` is that
  hook; calling it here runs the identical verifier list against the identical
  DSL state, and `Spark.Dsl`'s `:test_collector` (a pid in the *calling*
  process's dictionary, which is why the compiler's own run cannot use it) hands
  back the errors it would otherwise raise.

  `async: false` because suppressing the compiler's own report means swapping
  the global `:standard_error` device.
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

  # The errors the compiler would have raised, for a resource built from `body`.
  defp verifier_errors(body) do
    name = "VersioningProbe#{:erlang.unique_integer([:positive])}"

    source = """
    defmodule #{name} do
      use Ash.Resource,
        domain: AshQuick.VersioningVerifierTest.Domain,
        extensions: [AshQuick]

      ash_quick do
        # A probe carries neither naming convention, so it says what it is
        # called rather than resolving to nothing.
        display do
          label :id
        end

        liveness do
          enabled? false
        end

        # A probe is attributes only, so it carries none of the four bookkeeping
        # fields and has to say so — see `AshQuick.BookkeepingVerifierTest`.
        bookkeeping do
          created_at false
          updated_at false
          created_by false
          updated_by false
        end
      end

      #{body}
    end
    """

    # The compiler reports the failure itself, on its own process — swallowed
    # here so a deliberate failure does not look like a broken test run.
    capture_io(:stderr, fn -> Code.compile_string(source) end)

    Process.put({Spark.Dsl, :test_collector}, self())
    module = Module.concat([name])
    module.__verify_spark_dsl__(module)

    receive do
      {Spark.Dsl, :verifier_errors, ^module, errors} -> errors
    after
      0 -> []
    end
  end

  defp message(body) do
    assert [%Spark.Error.DslError{} = error] = verifier_errors(body)
    Exception.message(error)
  end

  test "a foreign :version refuses to compile, naming every way it differs" do
    # An outbox extension's shape: a schema version, nullable with no default.
    message =
      message("""
      attributes do
        uuid_primary_key :id
        attribute :version, :integer, public?: true
      end
      """)

    assert message =~ "already defines `version`"
    assert message =~ "default is nil, expected 1"
    assert message =~ "allow_nil? is true, expected false"
    assert message =~ "always_select? is false, expected true"

    # and it says how to get out of it, both ways
    assert message =~ "attribute :lock_version"
    assert message =~ "enabled? false"
  end

  test "a :version of the wrong type refuses to compile" do
    message =
      message("""
      attributes do
        uuid_primary_key :id
        attribute :version, :string, default: "1", allow_nil?: false, always_select?: true
      end
      """)

    assert message =~ "type is Ash.Type.String, expected Ash.Type.Integer"
  end

  test "a counter that already matches compiles, and is not added twice" do
    assert verifier_errors("""
           attributes do
             uuid_primary_key :id

             attribute :version, :integer,
               default: 1,
               allow_nil?: false,
               public?: true,
               always_select?: true
           end
           """) == []
  end

  test "opting out lets a foreign :version through untouched" do
    assert verifier_errors("""
           ash_quick do
             versioning do
               enabled? false
             end
           end

           attributes do
             uuid_primary_key :id
             attribute :version, :integer, public?: true
           end
           """) == []
  end

  test "locking on another column leaves the foreign one alone" do
    assert verifier_errors("""
           ash_quick do
             versioning do
               attribute :lock_version
             end
           end

           attributes do
             uuid_primary_key :id
             attribute :version, :integer, public?: true
           end
           """) == []
  end
end
