defmodule AshQuick.IdentityVerifierTest do
  @moduledoc """
  What the identity verifier will not let compile.

  AshQuick addresses a row by `:id` — DOM ids, the row-action events pushed back
  over the socket, the details route — none of which is about what the record is
  called. Addressing *a* row is the whole of it, so the attribute has to be both
  present and unique, and each half fails on its own with its own message.

  What arms it is the requirement that every resource AshQuick names carries
  the extension, which puts a composite-keyed join resource one ordinary PR
  away from a page whose rows all share the same element ids.

  Verifiers run in `@after_verify`, which the compiler executes in its own
  checker process — so the error is reported there and never propagates out of
  `Code.compile_string/1` for a test to catch. `__verify_spark_dsl__/1` is that
  hook; calling it here runs the identical verifier list against the identical
  DSL state, and `Spark.Dsl`'s `:test_collector` (a pid in the *calling*
  process's dictionary, which is why the compiler's own run cannot use it) hands
  back the errors it would otherwise raise.

  `async: false` because suppressing the compiler's own report means swapping the
  global `:standard_error` device.
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

  # A resource built from `body`. Bookkeeping is disclaimed wholesale so that a
  # probe about identity reports on identity — the generated `created_by` would
  # otherwise be the only thing a reader saw.
  defp probe(body) do
    name = "IdentityProbe#{:erlang.unique_integer([:positive])}"

    source = """
    defmodule #{name} do
      use Ash.Resource,
        domain: AshQuick.IdentityVerifierTest.Domain,
        extensions: [AshQuick]

      ash_quick do
        bookkeeping do
          created_at false
          updated_at false
          created_by false
          updated_by false
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

  test "a composite primary key and no :id does not compile" do
    # A join resource whose key is the pair of columns it joins, with a real
    # label so the display side has nothing to say and the failure is
    # identity's alone.
    message =
      message("""
      attributes do
        attribute :name, :string, public?: true
      end

      relationships do
        belongs_to :left, AshQuick.Test.Tenant do
          domain AshQuick.Test.Accounts
          primary_key? true
          allow_nil? false
        end

        belongs_to :right, AshQuick.Test.Actor do
          domain AshQuick.Test.Accounts
          primary_key? true
          allow_nil? false
        end
      end
      """)

    assert message =~ "carries the AshQuick extension and has no `:id` attribute"

    # The reason has to be row addressing and not labelling: a reader told this
    # was about the display label would "fix" it with a `label` declaration and
    # get the same error back.
    assert message =~ "AshQuick addresses a row by `:id`"
    assert message =~ "about identity and not about labelling"

    # Both ways out, since which one is right depends on whether the resource is
    # ever meant to be rendered.
    assert message =~ "uuid_primary_key :id"
    assert message =~ "drop the extension from a resource no QuickView will ever render"
  end

  test "a primary key by another name is still no :id" do
    # The row-action events push `%{id: record.id}`, so the requirement is the
    # field and not the key — a resource keyed on `:code` has nothing to put in
    # that value.
    assert message("""
           attributes do
             attribute :code, :string, primary_key?: true, allow_nil?: false, public?: true
             attribute :name, :string, public?: true
           end
           """) =~ "has no `:id` attribute"
  end

  test "an :id that is not the primary key satisfies it, once it is unique" do
    # Deliberately not tightened to the primary key: the views read the
    # attribute and never `Ash.Resource.Info.primary_key/1`, so a resource
    # keyed on something else qualifies by declaring what its `:id` already is.
    assert verifier_errors("""
           attributes do
             attribute :code, :string, primary_key?: true, allow_nil?: false, public?: true
             attribute :id, :uuid, allow_nil?: false, public?: true
             attribute :name, :string, public?: true
           end

           identities do
             identity :unique_id, [:id]
           end
           """) == []
  end

  test "an :id nothing makes unique does not compile" do
    # The same probe without the identity. Presence alone is not the
    # requirement: `load_record!/3` filters `id == ^id` and reads it through
    # `Ash.read_one/2`, and a row action takes the first matching `:id` on the
    # page — a repeated one is a not-found details page and an arbitrary row
    # acted on.
    message =
      message("""
      attributes do
        attribute :code, :string, primary_key?: true, allow_nil?: false, public?: true
        attribute :id, :uuid, allow_nil?: false, public?: true
        attribute :name, :string, public?: true
      end
      """)

    assert message =~ "nothing makes its `:id` unique"

    # Both ways out, and the one a reader of the message is most likely to reach
    # for — the resource already has its own key, so adding the identity is the
    # answer rather than restructuring it.
    assert message =~ "identity :unique_id, [:id]"
    assert message =~ "uuid_primary_key :id"

    # The failure has to be nameable as its own thing: told only that the
    # resource "has no :id", whoever hits this would go looking for the
    # attribute that is right there.
    refute message =~ "has no `:id` attribute"
  end

  test "an :id that is one column of a composite key does not compile" do
    # It is present and it is part of the primary key, and it still repeats
    # across every row sharing it.
    assert message("""
           attributes do
             attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
             attribute :revision, :integer, primary_key?: true, allow_nil?: false, public?: true
             attribute :name, :string, public?: true
           end
           """) =~ "nothing makes its `:id` unique"
  end

  test "a resource with :id compiles" do
    assert verifier_errors("""
           attributes do
             uuid_primary_key :id
             attribute :name, :string, public?: true
           end
           """) == []
  end
end
