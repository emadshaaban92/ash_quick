defmodule AshQuick.BookkeepingVerifierTest do
  @moduledoc """
  What the bookkeeping transformer generates, what it refuses to touch, and what
  the verifier will not let compile.

  The two halves are one mechanism. The transformer is add-if-absent, so a
  resource's own declaration always wins and the generated form only fills a
  gap; the verifier is what stops the gap being filled *wrongly* — a field
  claimed that is not there, one that is there and disclaimed, or a timestamp
  that is not `always_select?`.

  The disclaimed direction is the one with teeth: a resource that *has*
  `updated_by` but declares it absent drops the column out of
  `AshQuick.Config.versioning_ignored_attributes/1`, and its optimistic lock
  starts bumping `version` on writes that used to be no-ops. Nothing observable
  fails; the counter just climbs.

  Verifiers run in `@after_verify`, which the compiler executes in its own
  checker process — so the error is reported there and never propagates out of
  `Code.compile_string/1` for a test to catch. `__verify_spark_dsl__/1` is that
  hook; calling it here runs the identical verifier list against the identical
  DSL state, and `Spark.Dsl`'s `:test_collector` (a pid in the *calling*
  process's dictionary, which is why the compiler's own run cannot use it) hands
  back the errors it would otherwise raise.

  `async: false` because suppressing the compiler's own report means swapping
  the global `:standard_error` device, and four tests here swap the
  `:actor_resource` config.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Ash.Resource.Change
  alias Ash.Resource.Info

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  # A resource built from `body`. The template declares no bookkeeping, so a
  # probe starts out claiming all four and the transformer fills them in; a test
  # about one field opts out of the other three in its own `body`.
  defp probe(body) do
    name = "BookkeepingProbe#{:erlang.unique_integer([:positive])}"

    source = """
    defmodule #{name} do
      use Ash.Resource,
        domain: AshQuick.BookkeepingVerifierTest.Domain,
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
      end

      #{body}
    end
    """

    # The compiler reports a verifier failure itself, on its own process —
    # swallowed here so a deliberate failure does not look like a broken run.
    capture_io(:stderr, fn -> Code.compile_string(source) end)
    Module.concat([name])
  end

  # The errors the compiler would have raised for that probe.
  defp verifier_errors(body) do
    module = probe(body)
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

  # Compiles `body` against a different `:actor_resource` than the suite runs
  # with. `nil` is the only route left to a *missing* actor relationship — with
  # one configured the transformer would simply add it.
  #
  # Put rather than deleted: the key is pinned with `compile_env`, so an absent
  # one falls back to what the suite was compiled against instead of taking the
  # value under test.
  defp with_actor_resource(resource, fun) do
    original = Application.get_env(:ash_quick, :actor_resource)

    Application.put_env(:ash_quick, :actor_resource, resource)

    try do
      fun.()
    after
      Application.put_env(:ash_quick, :actor_resource, original)
    end
  end

  describe "what the transformer generates" do
    test "a resource declaring nothing gets all four, and they compile" do
      body = """
      attributes do
        uuid_primary_key :id
      end
      """

      assert verifier_errors(body) == []
      module = probe(body)

      created_at = Info.attribute(module, :created_at)
      updated_at = Info.attribute(module, :updated_at)

      # `always_select?` is the point of generating them rather than leaving the
      # convention to each resource: a details header reads these off a record
      # whose select list came from a QuickView's `fields:` option.
      assert {created_at.public?, created_at.always_select?} == {true, true}
      assert {updated_at.public?, updated_at.always_select?} == {true, true}

      for field <- [:created_by, :updated_by] do
        relationship = Info.relationship(module, field)

        assert relationship.destination == AshQuick.Config.actor_resource()
        assert {relationship.allow_nil?, relationship.public?} == {false, true}

        # The probe lives in this test's own domain, so this is the destination's
        # domain and not the source's — the relationship crosses domains, and
        # the transformer reads the actor resource's domain off the resource
        # rather than taking it as a second config key.
        assert relationship.domain == AshQuick.Test.Accounts

        # The `belongs_to` brings its own column, which is what
        # `AshQuick.Info.actor_attributes/1` reads back.
        assert Info.attribute(module, relationship.source_attribute)
      end

      assert AshQuick.Info.actor_attributes(module) == [:created_by_id, :updated_by_id]
    end

    test "the actor is stamped, on create for created_by and on every write for updated_by" do
      module =
        probe("""
        attributes do
          uuid_primary_key :id
        end
        """)

      stamped =
        for type <- [:create, :update],
            change <- Info.changes(module, type),
            %{change: {Change.RelateActor, opts}} <- [change],
            do: {type, opts[:relationship], opts[:allow_nil?]}

      # `allow_nil?: false` comes from `relate_actor/1` itself — the generated
      # change is built through the builtin so it cannot drift from what a
      # hand-written `change relate_actor(:created_by)` produces.
      assert Enum.sort(stamped) == [
               {:create, :created_by, false},
               {:create, :updated_by, false},
               {:update, :updated_by, false}
             ]
    end

    test "a field declared absent is not generated" do
      module =
        probe("""
        ash_quick do
          bookkeeping do
            updated_at false
            updated_by false
          end
        end

        attributes do
          uuid_primary_key :id
        end
        """)

      assert Info.attribute(module, :created_at)
      assert Info.relationship(module, :created_by)
      refute Info.attribute(module, :updated_at)
      refute Info.relationship(module, :updated_by)
      refute Info.attribute(module, :updated_by_id)
    end
  end

  describe "what the transformer leaves alone" do
    test "a hand-written relationship keeps its own options" do
      module =
        probe("""
        ash_quick do
          bookkeeping do
            updated_at false
            updated_by false
          end
        end

        attributes do
          uuid_primary_key :id
        end

        relationships do
          belongs_to :created_by, AshQuick.Test.Actor do
            domain AshQuick.Test.Accounts
            public? false
            allow_nil? true
          end
        end
        """)

      relationship = Info.relationship(module, :created_by)

      # A host keeping a `public? false` or `allow_nil? true` actor
      # relationship means it: generating over one would change what the API
      # exposes and what the column permits.
      assert {relationship.allow_nil?, relationship.public?} == {true, false}
    end

    test "a resource stamping inside one action is not also stamped globally" do
      module =
        probe("""
        ash_quick do
          bookkeeping do
            created_at false
            updated_at false
            updated_by false
          end
        end

        attributes do
          uuid_primary_key :id
        end

        relationships do
          belongs_to :created_by, AshQuick.Test.Actor do
            domain AshQuick.Test.Accounts
          end
        end

        actions do
          defaults [:read]

          create :file do
            change relate_actor(:created_by)
          end
        end
        """)

      # A resource stamping `:created_by` inside a single action means that one
      # action. A global change added alongside would both double-stamp and
      # widen the stamping to every create the resource has. Auditing is on by
      # default, so the change a probe does carry is the audit one — anything
      # else here is a stamp.
      assert Enum.reject(
               Info.changes(module, :create),
               &match?(%{change: {AshQuick.Audit.Change, _opts}}, &1)
             ) == []
    end
  end

  describe "an actor relationship pointing at something other than the actor" do
    # `:created_by` naming a relationship to something other than the
    # configured `:actor_resource`. Only the name suggests it is about the
    # actor, and the name is the one thing that must not decide.
    defp foreign_actor(declaration) do
      """
      ash_quick do
        bookkeeping do
          created_at false
          updated_at false
          updated_by false
          #{declaration}
        end
      end

      attributes do
        uuid_primary_key :id
      end

      relationships do
        belongs_to :created_by, AshQuick.Test.Tenant do
          domain AshQuick.Test.Accounts
        end
      end
      """
    end

    test "does not compile while it is declared" do
      message = message(foreign_actor("created_by :created_by"))

      assert message =~
               "created_by names :created_by, which is a relationship to " <>
                 "AshQuick.Test.Tenant rather than to AshQuick.Test.Actor"

      # The fix is to disclaim it — the relationship is real and keeps its name.
      assert message =~ "created_by false"
    end

    test "is not stamped with the actor" do
      module = probe(foreign_actor("created_by :created_by"))

      # The verifier refuses this resource, so nothing here reaches production
      # through the transformer. It is guarded anyway because the two have to
      # agree on what an actor relationship is: a `relate_actor` here would write
      # a user's id into a foreign key against `sellers`.
      refute Enum.any?(
               Info.changes(module, :create),
               &match?(%{change: {Change.RelateActor, _}}, &1)
             )
    end

    test "declared absent, it compiles and its column stays under the lock" do
      body = foreign_actor("created_by false")

      assert verifier_errors(body) == []
      module = probe(body)

      # Kept whole, and no longer claimed as bookkeeping — so a write changing
      # which seller a record points at bumps the optimistic lock, which is
      # right: that is a change to the record, not a stamp on it.
      assert Info.relationship(module, :created_by).destination == AshQuick.Test.Tenant
      assert AshQuick.Info.actor_fields(module) == []
      refute :created_by_id in AshQuick.Config.versioning_ignored_attributes(module)
      refute :created_by in AshQuick.Config.versioning_ignored_relationships(module)
    end
  end

  describe "what will not compile" do
    test "a field declared absent that the resource actually has" do
      message =
        message("""
        ash_quick do
          bookkeeping do
            created_at false
            created_by false
            updated_by false
          end
        end

        attributes do
          uuid_primary_key :id
          create_timestamp :created_at, always_select?: true
        end
        """)

      assert message =~
               "created_at defaults to :created_at, which this resource defines but declares absent"

      # The suggestion for this direction is to declare it, not to opt out.
      assert message =~ "created_at :created_at"
      refute message =~ "created_at false"
    end

    test "a hand-written timestamp that is not always_select?" do
      message =
        message("""
        ash_quick do
          bookkeeping do
            updated_at false
            created_by false
            updated_by false
          end
        end

        attributes do
          uuid_primary_key :id
          create_timestamp :created_at
        end
        """)

      assert message =~ "created_at names :created_at, which is not `always_select?: true`"
      assert message =~ "add that option to the attribute itself"
    end

    test "an actor declared with no :actor_resource configured to point it at" do
      with_actor_resource(nil, fn ->
        message =
          message("""
          ash_quick do
            bookkeeping do
              created_at false
              updated_at false
              updated_by false
            end
          end

          attributes do
            uuid_primary_key :id
          end
          """)

        assert message =~
                 "created_by is declared as :created_by, which this resource does not define"

        assert message =~ "created_by false"
      end)
    end

    test "an actor column is not an actor relationship" do
      with_actor_resource(nil, fn ->
        # `:created_by` names the relationship, and the ignore list reads the
        # source attribute off it — the column alone is not the declaration.
        message =
          message("""
          ash_quick do
            bookkeeping do
              created_at false
              updated_at false
              updated_by false
            end
          end

          attributes do
            uuid_primary_key :id
            attribute :created_by_id, :uuid
          end
          """)

        assert message =~
                 "created_by is declared as :created_by, which this resource does not define"
      end)
    end

    # The stamped relationship compiles fine; what does not is the header that
    # renders it. `AshQuick.Info.display_label/1` raises for a resource without
    # the extension, and `AshQuick.LiveView.DetailsUtils.actor_load/1` asks it
    # for one on every details page in the app — so the resource that stamps an
    # actor is refused here instead.
    test "the configured actor resource does not carry the extension" do
      with_actor_resource(AshQuick.Test.PlainRecord, fn ->
        message =
          message("""
          ash_quick do
            bookkeeping do
              created_at false
              updated_at false
            end
          end

          attributes do
            uuid_primary_key :id
          end
          """)

        assert message =~
                 "stamps an actor, and the configured `:actor_resource` " <>
                   "AshQuick.Test.PlainRecord does not carry the AshQuick extension"

        assert message =~ "extensions: [AshQuick, ...]"
      end)
    end

    test "a resource stamping no actor compiles against an unlabellable one" do
      with_actor_resource(AshQuick.Test.PlainRecord, fn ->
        assert verifier_errors("""
               ash_quick do
                 bookkeeping do
                   created_at false
                   updated_at false
                   created_by false
                   updated_by false
                 end
               end

               attributes do
                 uuid_primary_key :id
               end
               """) == []
      end)
    end
  end

  describe "a renamed field" do
    test "is taken at its word, and generated under the name given" do
      module =
        probe("""
        ash_quick do
          bookkeeping do
            created_at :inserted_at
            updated_at false
            created_by false
            updated_by false
          end
        end

        attributes do
          uuid_primary_key :id
        end
        """)

      assert Info.attribute(module, :inserted_at).always_select?
      refute Info.attribute(module, :created_at)
    end

    test "does not satisfy itself with the conventionally-named one" do
      message =
        message("""
        ash_quick do
          bookkeeping do
            created_at :inserted_at
            updated_at false
            created_by false
            updated_by false
          end
        end

        attributes do
          uuid_primary_key :id
          create_timestamp :inserted_at
          create_timestamp :created_at, always_select?: true
        end
        """)

      # `:created_at` being present is beside the point; the declaration named
      # `:inserted_at`, and that is the field every reader will go to.
      assert message =~ "created_at names :inserted_at, which is not `always_select?: true`"
    end
  end
end
