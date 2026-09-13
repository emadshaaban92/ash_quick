defmodule AshQuick.AuditVerifierTest do
  @moduledoc """
  A resource that audits with no usable store behind it must not compile.

  Auditing is on unless a resource turns it off, and there is deliberately
  nowhere else for an entry to go — no logging it somewhere, no dropping it. So
  every resource carrying the extension needs a store that can take the row,
  and the gap is invisible until a write happens: `Ash.bulk_create` into
  `nil`, or into a resource with no column to put `ip` in, raised inside the
  action's transaction, on every create, update and destroy the resource has.
  Moving that to compile time is the whole point of this verifier — the failure
  belongs to the configuration, not to whoever next saves a record.

  Both routes into auditing are covered, because the verifier looks at the
  attached change rather than at the declaration: a resource that turns the
  section off and attaches `AshQuick.Audit.Change` to one of its actions is
  audited just as much as one that declares nothing.

  Verifiers run in `@after_verify`, which the compiler executes in its own
  checker process — so the error is reported there and never propagates out of
  `Code.compile_string/1` for a test to catch. `__verify_spark_dsl__/1` is that
  hook; calling it here runs the identical verifier list against the identical
  DSL state, and `Spark.Dsl`'s `:test_collector` (a pid in the *calling*
  process's dictionary, which is why the compiler's own run cannot use it) hands
  back the errors it would otherwise raise.

  `async: false` because suppressing the compiler's own report means swapping
  the global `:standard_error` device, and every test here swaps the
  `:audit_resource` config.

  The stores this configures live in `test/support/audit_resources.ex` rather
  than here, because `use Ash.Resource` defines an `Inspect` implementation and
  a `.exs` file is compiled after protocol consolidation — one defined here is
  discarded, with a warning per resource. The probes escape that only because
  the `capture_io(:stderr, ...)` around their compilation swallows it too.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshQuick.Test.ArgumentAuditStore
  alias AshQuick.Test.PartialAuditStore
  alias AshQuick.Test.PrivateAuditStore
  alias AshQuick.Test.ReadOnlyAuditStore

  defmodule NotAStore do
    @moduledoc false
    # Configured in place of a store: a real module, reachable, not a resource.
    def create(_row), do: :ok
  end

  # Never defined anywhere: a name that resolves to nothing, which is what a
  # typo in `config.exs` or in `store` leaves behind.
  @no_such_store AshQuick.AuditVerifierTest.NoSuchStore

  # Compiles `body` against a different `:audit_resource` than the suite runs
  # with.
  defp with_audit_resource(store, fun) do
    original = Application.get_env(:ash_quick, :audit_resource)

    Application.put_env(:ash_quick, :audit_resource, store)

    try do
      fun.()
    after
      Application.put_env(:ash_quick, :audit_resource, original)
    end
  end

  defp probe(name, body, use_opts \\ "domain: AshQuick.Test.AuditDomain") do
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

    # The compiler reports a failure itself, on its own process — swallowed here
    # so a deliberate failure does not look like a broken test run.
    capture_io(:stderr, fn -> Code.compile_string(source) end)

    Module.concat([name])
  end

  defp name, do: "AuditProbe#{:erlang.unique_integer([:positive])}"

  # The errors the compiler would have raised, for a resource built from `body`.
  defp verifier_errors(body) do
    module = probe(name(), body)

    Process.put({Spark.Dsl, :test_collector}, self())
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

  defp audit_change?(%{change: {AshQuick.Audit.Change, _opts}}), do: true
  defp audit_change?(_change), do: false

  defp audited?(resource) do
    Enum.any?(Ash.Resource.Info.changes(resource), &audit_change?/1) or
      Enum.any?(Ash.Resource.Info.actions(resource), fn action ->
        Enum.any?(Map.get(action, :changes) || [], &audit_change?/1)
      end)
  end

  # Auditing is on unless a resource turns it off, so this declares nothing.
  @default """
  attributes do
    uuid_primary_key :id
  end
  """

  # The second route: audit off at resource level, the change attached to one
  # action.
  @hand_attached """
  ash_quick do
    audit do
      enabled? false
    end
  end

  actions do
    defaults [:read]

    update :touch do
      change AshQuick.Audit.Change
    end
  end

  attributes do
    uuid_primary_key :id
  end
  """

  @off """
  ash_quick do
    audit do
      enabled? false
    end
  end

  attributes do
    uuid_primary_key :id
  end
  """

  test "a resource that declares nothing is audited, and needs a store to be" do
    message = with_audit_resource(nil, fn -> message(@default) end)

    assert message =~ "is audited, and there is no audit store to write to"

    # It fails on every write, not here — that is why this check exists at all.
    assert message =~ "inside the action's transaction"

    # and it says how to get out of it, every way
    assert message =~ "mix igniter.install ash_quick"
    assert message =~ "audit_resource: MyApp.AuditLog"
    assert message =~ "store MyApp.SecurityLog"
    assert message =~ "enabled? false"
    assert message =~ "remove `change AshQuick.Audit.Change`"
  end

  test "a store configured in runtime.exs is named as the mistake it looks like" do
    message = with_audit_resource(nil, fn -> message(@default) end)

    assert message =~ "in `config.exs` rather than `runtime.exs`"
  end

  test "a configured store that is not a resource refuses to compile, naming it" do
    message = with_audit_resource(NotAStore, fn -> message(@default) end)

    assert message =~ "is not an Ash resource"
    assert message =~ inspect(NotAStore)
  end

  test "a configured store that does not exist refuses to compile, naming it" do
    message = with_audit_resource(@no_such_store, fn -> message(@default) end)

    assert message =~ "does not exist"
    assert message =~ inspect(@no_such_store)

    # A name that resolves to nothing is a typo or a store configured too late
    # to be seen, and the second one reads exactly like the first.
    assert message =~ "in `config.exs` rather than `runtime.exs`"
  end

  test "a resource naming a store that does not exist is caught the same way" do
    # The DSL takes it: `{:spark, Ash.Resource}` does not resolve the module, so
    # nothing before this verifier notices.
    message =
      message("""
      ash_quick do
        audit do
          store AshQuick.AuditVerifierTest.NoSuchStore
        end
      end

      attributes do
        uuid_primary_key :id
      end
      """)

    assert message =~ "does not exist"
    assert message =~ inspect(@no_such_store)
  end

  test "a store with no :create action refuses to compile, saying that" do
    message = with_audit_resource(ReadOnlyAuditStore, fn -> message(@default) end)

    assert message =~ inspect(ReadOnlyAuditStore)
    assert message =~ "has no `:create` action"

    # Every column is present, so the report is the missing action rather than
    # eleven columns an action that is not there does not accept.
    refute message =~ "does not accept"
  end

  test "a store taking a column through an argument is not refused for it" do
    assert with_audit_resource(ArgumentAuditStore, fn -> verifier_errors(@default) end) == []
  end

  test "a store missing a column AshQuick fills refuses to compile, naming the columns" do
    message = with_audit_resource(PartialAuditStore, fn -> message(@default) end)

    assert message =~ inspect(PartialAuditStore)
    assert message =~ "it has no `ip`, `tenant`"

    # The whole row is listed too, so the fix is not one column at a time.
    assert message =~ "`real_actor_id`"
  end

  test "a store whose :create will not take the row refuses to compile, naming the columns" do
    message = with_audit_resource(PrivateAuditStore, fn -> message(@default) end)

    # The columns are all there; `accept :*` skips the private ones, and the
    # write would fail with `NoSuchInput` one save later.
    assert message =~ inspect(PrivateAuditStore)
    assert message =~ "its `:create` action does not accept `context`, `ip`"
  end

  test "a resource naming its own store is held to that one, not the app's" do
    message =
      message("""
      ash_quick do
        audit do
          store AshQuick.Test.PartialAuditStore
        end
      end

      attributes do
        uuid_primary_key :id
      end
      """)

    assert message =~ inspect(PartialAuditStore)
    assert message =~ "it has no `ip`, `tenant`"
  end

  test "auditing by hand, with the section off, is caught the same way" do
    message = with_audit_resource(nil, fn -> message(@hand_attached) end)

    assert message =~ "is audited, and there is no audit store to write to"
  end

  test "a resource that turns audit off compiles with no store at all" do
    assert with_audit_resource(nil, fn -> verifier_errors(@off) end) == []
  end

  test "every route compiles under the configured store" do
    for body <- [@default, @hand_attached, @off] do
      assert verifier_errors(body) == []
    end

    assert Ash.Resource.Info.resource?(AshQuick.Config.audit_resource())
  end

  test "the store is not audited into itself, and needs no store of its own" do
    store = name()

    with_audit_resource(Module.concat([store]), fn ->
      module = probe(store, @default)

      refute audited?(module)
      assert verifier_errors(@off) == []
    end)
  end

  test "an embedded resource is not audited — it has no row of its own to name" do
    # Same body, same extension, one `data_layer:` apart — so the refutation
    # below can fail, and fails for the reason it names.
    assert audited?(probe(name(), @default))
    refute audited?(probe(name(), @default, "data_layer: :embedded"))
  end
end
