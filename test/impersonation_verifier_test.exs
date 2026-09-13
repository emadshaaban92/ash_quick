defmodule AshQuick.ImpersonationVerifierTest do
  @moduledoc """
  Impersonation is generated on the configured `:actor_resource` and on nothing
  else, and that resource must not compile without an audit trail or an
  authorizer.

  There is no declaration to make, so these are requirements on the actor
  resource itself. An impersonation writes nothing to either record — it lives
  in the browser tab that asked for it — so the entry the action leaves is the
  only record anywhere that one person browsed as another. Turning auditing off
  on the resource an actor is resolved from therefore does not make the
  escalation quieter, it makes it untraceable, and the tab can be somebody else
  for the rest of the working day. That pairing is the reason impersonation and
  audit ship in the same package: two packages could only document it.

  The store is the same requirement one step along, and this verifier
  deliberately does not restate it — requiring auditing is what drags
  `AshQuick.Audit.Verifier` in, and it reports a missing or unusable store
  itself. The third test here pins that the coupling really does reach that far.

  The mechanics of running a verifier from a test are
  `AshQuick.AuditVerifierTest`'s; the same notes apply, including `async: false`
  for the `:standard_error` swap and the config swaps. A probe becomes the actor
  resource by being named as one before it compiles, which is the only way to
  put a throwaway module in the position a host's user resource holds.
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

  @authorized "domain: AshQuick.ImpersonationVerifierTest.Domain, " <>
                "authorizers: [Ash.Policy.Authorizer]"

  @unauthorized "domain: AshQuick.ImpersonationVerifierTest.Domain"

  @plain """
  attributes do
    uuid_primary_key :id
  end
  """

  @unaudited """
  ash_quick do
    audit do
      enabled? false
    end
  end

  attributes do
    uuid_primary_key :id
  end
  """

  defp probe(name, body, use_opts) do
    source = """
    defmodule #{name} do
      use Ash.Resource,
        #{use_opts},
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
        # fields and has to say so.
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

    # The compiler reports a failure itself, on its own process — swallowed here
    # so a deliberate failure does not look like a broken test run.
    capture_io(:stderr, fn -> Code.compile_string(source) end)

    Module.concat([name])
  end

  defp name, do: "ImpersonationProbe#{:erlang.unique_integer([:positive])}"

  # The errors the compiler would have raised, for a resource built from `body`.
  defp verifier_errors(module) do
    Process.put({Spark.Dsl, :test_collector}, self())
    module.__verify_spark_dsl__(module)

    receive do
      {Spark.Dsl, :verifier_errors, ^module, errors} -> errors
    after
      0 -> []
    end
  end

  defp message(module) do
    assert [%Spark.Error.DslError{} = error] = verifier_errors(module)
    Exception.message(error)
  end

  # Compiles `body` as the host's actor resource and hands it to `fun`, since
  # that is the only position impersonation is generated in. The name is settled
  # before the module exists, so the config is already pointing at it while its
  # transformers run — and `fun` is called while it still is, because verifying
  # asks the same question a second time.
  defp actor_probe(body, use_opts, overrides, fun) do
    name = name()

    with_config([actor_resource: Module.concat([name])] ++ overrides, fn ->
      fun.(probe(name, body, use_opts))
    end)
  end

  defp with_config(overrides, fun) do
    original = Enum.map(overrides, fn {key, _} -> {key, Application.get_env(:ash_quick, key)} end)

    Enum.each(overrides, fn {key, value} -> Application.put_env(:ash_quick, key, value) end)

    try do
      fun.()
    after
      Enum.each(original, fn {key, value} -> Application.put_env(:ash_quick, key, value) end)
    end
  end

  describe "the actor resource" do
    test "gains the action by being the actor resource" do
      actor_probe(@plain, @authorized, [], fn module ->
        assert %Ash.Resource.Actions.Update{manual: {AshQuick.Impersonation.NoOp, []}} =
                 Ash.Resource.Info.action(module, :impersonate)

        assert AshQuick.Impersonation.resource?(module)
        assert verifier_errors(module) == []
      end)
    end

    # The escalation is the actor resource's alone: everything else in the app
    # carries the extension too, and an `:impersonate` on an order or a product
    # would be an action nothing can ever resolve a token to.
    #
    # Probed with neither of the things the actor resource may not go without,
    # so both halves of that answer can fail: a transformer that stopped asking
    # gives it the action, and a verifier that stopped asking refuses to compile
    # an ordinary unaudited resource over an escalation it was never offered.
    test "is the only resource that gains it, or answers for it" do
      module = probe(name(), @unaudited, @unauthorized)

      refute AshQuick.Impersonation.resource?(module)
      assert is_nil(Ash.Resource.Info.action(module, :impersonate))
      assert verifier_errors(module) == []
    end

    test "answers to the name the token and the register spell" do
      assert AshQuick.Impersonation.action() == :impersonate
    end
  end

  describe "impersonation cannot be had without an audit trail" do
    test "an actor resource with auditing turned off does not compile" do
      message = actor_probe(@unaudited, @authorized, [], &message/1)

      assert message =~ "is the configured `:actor_resource`"
      assert message =~ "it is not audited"
      assert message =~ "the only record there is"
    end

    # Requiring the audit is what pulls the store requirement in: the resource
    # is audited, so `AshQuick.Audit.Verifier` has a say and takes it.
    test "one whose store does not resolve is refused by the audit verifier" do
      message = actor_probe(@plain, @authorized, [audit_resource: nil], &message/1)

      assert message =~ "there is no audit store to write to"
    end
  end

  describe "impersonation cannot be had without an authorizer" do
    test "an actor resource with no authorizer does not compile" do
      message = actor_probe(@plain, @unauthorized, [], &message/1)

      assert message =~ "nothing authorizes that action"
      assert message =~ "authorizers: [Ash.Policy.Authorizer]"
    end
  end

  describe "a resource writing the action itself" do
    @own_action """
    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]

      update :impersonate do
        accept []
        require_atomic? false
        description "hand written"

        manual fn changeset, _context -> {:ok, changeset.data} end
      end
    end
    """

    test "keeps it whole" do
      actor_probe(@own_action, @authorized, [], fn module ->
        assert %Ash.Resource.Actions.Update{description: "hand written"} =
                 Ash.Resource.Info.action(module, :impersonate)
      end)
    end
  end

  describe "the resource an impersonation names" do
    test "is refused when the host configured none" do
      assert_raise ArgumentError, ~r/needs to know what an actor is/, fn ->
        with_config([actor_resource: nil], &AshQuick.Impersonation.resource!/0)
      end
    end

    # The gap `AshQuick.Bookkeeping.Verifier` leaves: it refuses an actor
    # resource without the extension only for a host whose resources stamp an
    # actor at all. Without this the miss surfaces as `Ash.can?/3` raising
    # `NoSuchAction`, naming the action rather than the resource that was
    # supposed to carry it.
    test "is refused when it carries no generated action" do
      assert_raise ArgumentError, ~r/does not have one, which means no transformer ran/, fn ->
        with_config([actor_resource: __MODULE__], &AshQuick.Impersonation.resource!/0)
      end
    end

    test "is the configured one, untouched" do
      assert AshQuick.Impersonation.resource!() == AshQuick.Test.Actor
    end
  end
end
