defmodule AshQuick.ScopeTest do
  @moduledoc """
  The parts of the provenance contract that have no user-visible surface.

  Everything the contract is *for* — a real actor and an IP on an audit row,
  under impersonation and without it — a host drives through the browser. What
  is left here is what cannot be: a `use AshQuick.Scope` that refuses to
  compile is not something a page can be visited to observe, and
  `contract_violations/1` is a report a host asserts on in a test of its own,
  with no surface.
  """
  use ExUnit.Case, async: true

  alias AshQuick.Scope
  alias AshQuick.Scope.Provenance
  alias AshQuick.Test.Scopes.{DerivedScope, FullScope, LegacyScope, MinimalScope, NotAScope}
  alias AshQuick.Test.Tenant

  # A scope module is only ever written once per project, so a name that fails
  # to compile fails forever — silently returning `nil` for it is the outcome
  # the macro exists to prevent.
  describe "declaring a scope" do
    test "a field the struct does not have is refused at compile time" do
      assert_raise ArgumentError,
                   ~r/names :remote_ip as its :ip, but the struct has no such/,
                   fn ->
                     compile(
                       "use AshQuick.Scope, actor: :user, ip: :remote_ip",
                       "defstruct [:user]"
                     )
                   end
    end

    test "the actor is required, since nothing else can be derived without it" do
      assert_raise ArgumentError, ~r/requires :actor/, fn ->
        compile("use AshQuick.Scope, tenant: :seller", "defstruct [:seller]")
      end
    end

    test "an option AshQuick does not know is a typo, not an extension point" do
      assert_raise ArgumentError, ~r/unknown `use AshQuick.Scope` option :real_users/, fn ->
        compile("use AshQuick.Scope, actor: :user, real_users: :behind", "defstruct [:user]")
      end
    end

    test "a value that is not a field name is refused" do
      assert_raise ArgumentError, ~r/expects :actor to name a struct field as an atom/, fn ->
        compile(~s|use AshQuick.Scope, actor: "user"|, "defstruct [:user]")
      end
    end

    test "a module with no struct is refused" do
      assert_raise ArgumentError, ~r/requires the module to define a struct/, fn ->
        compile("use AshQuick.Scope, actor: :user", "")
      end
    end
  end

  describe "reading a scope" do
    test "a scope declaring everything answers from its own fields" do
      scope = %FullScope{
        user: %{id: 2},
        seller: "seller-1",
        behind: %{id: 1},
        pretending?: true,
        from: "10.0.0.9",
        tz: "Asia/Tokyo",
        lang: "ar"
      }

      assert Scope.actor(scope) == %{id: 2}
      assert Scope.tenant(scope) == "seller-1"
      assert Scope.real_actor(scope) == %{id: 1}
      assert Scope.impersonating?(scope)
      assert Scope.ip(scope) == "10.0.0.9"
      assert Scope.timezone(scope) == "Asia/Tokyo"
      assert Scope.locale(scope) == "ar"
    end

    # The point of the default: the column is ready for impersonation without
    # the host having any.
    test "a scope declaring only an actor is its own real actor" do
      scope = %MinimalScope{user: %{id: 7}}

      assert Scope.real_actor(scope) == %{id: 7}
      refute Scope.impersonating?(scope)
      assert Scope.ip(scope) == nil
    end

    test "an undeclared timezone and locale fall back to the application's" do
      scope = %MinimalScope{user: %{id: 7}}

      assert Scope.timezone(scope) == AshQuick.Config.timezone()
      assert Scope.locale(scope) == AshQuick.Config.locale()
    end

    # Two loads of the same user differ on whichever calculations each carried,
    # so the comparison has to be on identity.
    test "impersonation is derived by identity when the scope states no flag" do
      differently_loaded = %DerivedScope{user: %{id: 3, name: "a"}, behind: %{id: 3}}
      genuinely_two = %DerivedScope{user: %{id: 3}, behind: %{id: 4}}

      refute Scope.impersonating?(differently_loaded)
      assert Scope.impersonating?(genuinely_two)
    end

    test "a scope that never heard of the contract still names a real actor" do
      assert Scope.real_actor(%LegacyScope{user: %{id: 5}}) == %{id: 5}
      assert Scope.ip(%LegacyScope{user: %{id: 5}}) == nil
    end

    # A host seam taking one `:scope` reads both the actor and the tenant off
    # it, so a subject the actor answers for and the tenant does not files the
    # work under nobody.
    test "a changeset, a query and an action input answer for the tenant too" do
      tenant = "seller-#{:erlang.unique_integer([:positive])}"
      actor = %{id: :erlang.unique_integer([:positive])}
      context = %{private: %{actor: actor}}

      subjects = [
        Tenant |> Ash.Changeset.new() |> Ash.Changeset.set_tenant(tenant),
        Tenant |> Ash.Query.new() |> Ash.Query.set_tenant(tenant),
        Tenant |> Ash.ActionInput.new() |> Ash.ActionInput.set_tenant(tenant)
      ]

      for subject <- subjects do
        subject = %{subject | context: Map.merge(subject.context, context)}

        assert Scope.actor(subject) == actor
        assert Scope.tenant(subject) == tenant
      end
    end

    test "nothing at all is answered rather than raised" do
      assert Scope.provenance(nil) == %Provenance{}
      assert Scope.actor(nil) == nil
      assert Scope.tenant(nil) == nil
    end
  end

  describe "contract_violations/1" do
    test "a scope built by the macro satisfies the contract" do
      assert Scope.contract_violations(FullScope) == []
      assert Scope.contract_violations(MinimalScope) == []
      assert Scope.contract_violations(DerivedScope) == []
    end

    test "a hand-rolled Ash scope is reported for provenance and for context" do
      violations = Scope.contract_violations(LegacyScope)

      assert Enum.any?(violations, &(&1 =~ "does not implement AshQuick.Scope.ToProvenance"))
      assert Enum.any?(violations, &(&1 =~ "does not carry its provenance into action context"))
      refute Enum.any?(violations, &(&1 =~ "does not implement Ash.Scope.ToOpts"))
    end

    test "a module that is not a scope at all is reported rather than crashing" do
      assert Scope.contract_violations(NotAScope) == [
               "AshQuick.Test.Scopes.NotAScope defines no struct, so no scope can be built from it."
             ]

      assert [violation] = Scope.contract_violations(NoSuchModuleAnywhere)
      assert violation =~ "is not a loadable module"
    end
  end

  defp compile(use_line, struct_line) do
    module = "Probe#{:erlang.unique_integer([:positive])}"

    Code.eval_string("defmodule #{module} do\n#{use_line}\n#{struct_line}\nend", [],
      file: "scope_test_probe.exs"
    )
  end
end
