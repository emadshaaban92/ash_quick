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

  Each probe is compiled through `AshQuick.Test.VerifierErrors`, which says how
  a test gets hold of the errors the compiler's own run reports.

  `async: false` because suppressing the compiler's own report means swapping
  the global `:standard_error` device.
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

  # The errors the compiler would have raised, for a resource built from `body`.
  defp verifier_errors(body), do: VerifierErrors.errors(compile(body))

  defp compile(body) do
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
          inserted_at false
          updated_at false
          inserted_by false
          updated_by false
        end
      end

      #{body}
    end
    """

    VerifierErrors.compile(source)
    Module.concat([name])
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
    assert message =~ "writable? is true, expected false"

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
               always_select?: true,
               writable?: false
           end
           """) == []
  end

  test "the counter AshQuick adds is not writable, so accept :* leaves it out" do
    module =
      compile("""
      attributes do
        uuid_primary_key :id
        attribute :name, :string, public?: true
      end

      actions do
        default_accept :*
        defaults [:read, :create, :update]
      end
      """)

    refute Ash.Resource.Info.attribute(module, :version).writable?

    for action <- [:create, :update] do
      accepted = Ash.Resource.Info.action(module, action).accept
      assert :name in accepted
      refute :version in accepted
    end
  end

  test "a counter an action can write refuses to compile" do
    message =
      message("""
      attributes do
        uuid_primary_key :id

        attribute :version, :integer,
          default: 1,
          allow_nil?: false,
          public?: true,
          always_select?: true
      end
      """)

    assert message =~ "writable? is true, expected false"
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
