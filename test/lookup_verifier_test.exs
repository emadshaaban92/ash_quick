defmodule AshQuick.LookupVerifierTest do
  @moduledoc """
  What the lookup verifier will not let compile, and — just as deliberately —
  what it lets through.

  Everything a lookup action is asked for is asked because a caller does it:
  `Ash.Query.for_read/4` needs the action to exist, all four readers pass the
  search argument, and both the list (`Ash.Query.page/2`) and the dropdowns
  (`.results`) read a page back off the answer — which the dropdowns ask for
  without a limit of their own, so the pagination has to carry a
  `default_limit`. An action satisfying all but one of these fails at the reader
  rather than at the query — a non-paginated one hands back a bare list and
  raises `expected a map, got: []` inside the component.

  The scoping is the other half of what these pin. Whether a resource needs a
  lookup action at all is not a fact about the resource: it depends on a
  QuickView listing it or a `belongs_to` onto it being rendered. So this
  verifier only ever speaks about an action the resource *declared*, and the
  test that a resource declaring nothing compiles without one is load-bearing —
  widen it and the composite-keyed join resources are suddenly required to grow
  an `:index` no page will ever call. Absence is `AshQuick.LiveView.QuickView.Options`'
  to catch, where what points at what is known.

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

  @paginated """
  pagination do
    keyset? true
    offset? true
    default_limit 20
    countable :by_default
  end
  """

  # A resource built from `body`. Bookkeeping and liveness are disclaimed so a
  # probe about the lookup action reports on the lookup action.
  defp probe(body) do
    name = "LookupProbe#{:erlang.unique_integer([:positive])}"

    source = """
    defmodule #{name} do
      use Ash.Resource,
        domain: AshQuick.LookupVerifierTest.Domain,
        data_layer: Ash.DataLayer.Ets,
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

      attributes do
        uuid_primary_key :id
        attribute :name, :string, public?: true
      end

      #{body}
    end
    """

    # The compiler reports a verifier failure itself, on its own process —
    # swallowed here so a deliberate failure does not look like a broken run.
    capture_io(:stderr, fn -> Code.compile_string(source) end)
    Module.concat([name])
  end

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

  test "a declared action the resource does not define does not compile" do
    message =
      message("""
      ash_quick do
        lookup do
          action :find
        end
      end
      """)

    assert message =~ "defines no :find action"
    assert message =~ "This resource declares a `lookup` action AshQuick cannot search"

    # Both ways out, since which is right depends on whether the action or the
    # declaration is the thing that is wrong.
    assert message =~ "read :find do"
    assert message =~ "action :the_action"
  end

  test "a declared action that is not a read does not compile" do
    # `for_read/4` is what every caller reaches for, so naming a create here is
    # a query that cannot be built rather than one that returns the wrong rows.
    assert message("""
           ash_quick do
             lookup do
               action :create_it
             end
           end

           actions do
             defaults [:read]

             create :create_it do
               accept [:name]
             end
           end
           """) =~ "is a create action, not a read"
  end

  test "a read action that does not take the search argument does not compile" do
    assert message("""
           ash_quick do
             lookup do
               action :index
             end
           end

           actions do
             read :index do
               #{@paginated}
             end
           end
           """) =~ "takes no :search argument"
  end

  test "a read action whose search argument is required does not compile" do
    # The one that passes every other check and then fails on *every* read a
    # user does not type into: an unsearched open is the dropdown's normal
    # state and an empty box is the list's, and both send `nil`, which
    # `Ash.Query.require_arguments/2` refuses before the action ever runs.
    message =
      message("""
      ash_quick do
        lookup do
          action :index
        end
      end

      actions do
        read :index do
          argument :search, :string, allow_nil?: false
          #{@paginated}
        end
      end
      """)

    assert message =~ "requires its :search argument"
    assert message =~ "an unsearched read passes `nil` for it"
  end

  test "a read action that does not paginate does not compile" do
    # The half a reader would never guess: the action builds, reads and returns
    # perfectly good rows, and the caller raises on `.results` because a
    # non-paginated read hands back a bare list.
    message =
      message("""
      ash_quick do
        lookup do
          action :index
        end
      end

      actions do
        read :index do
          argument :search, :string
        end
      end
      """)

    assert message =~ "declares no pagination"
    assert message =~ "read `.results` off it"
  end

  test "a read action that paginates without a default limit does not compile" do
    # The one the list page hides: it passes `limit:` on every read, so the
    # action serves its own page perfectly and only the dropdowns — which open
    # on `Ash.Query.page(count: false)` and set no limit — ever meet the
    # failure. Ash raises `* Limit is required` under `required? true` and
    # hands back a bare list under `required? false`.
    message =
      message("""
      ash_quick do
        lookup do
          action :index
        end
      end

      actions do
        read :index do
          argument :search, :string

          pagination do
            keyset? true
            offset? true
            countable :by_default
          end
        end
      end
      """)

    assert message =~ "paginates without a `default_limit`"
    assert message =~ "a dropdown opens on a page it sets no limit of its own on"
  end

  test "the declared search argument is what the action is held to" do
    # The name is the resource's to choose, so a resource declaring `:query`
    # satisfies the verifier with `:query` and fails with `:search`.
    assert verifier_errors("""
           ash_quick do
             lookup do
               action :index
               search_argument :query
             end
           end

           actions do
             read :index do
               argument :query, :string
               #{@paginated}
             end
           end
           """) == []

    assert message("""
           ash_quick do
             lookup do
               search_argument :query
             end
           end

           actions do
             read :index do
               argument :search, :string
               #{@paginated}
             end
           end
           """) =~ "takes no :query argument"
  end

  test "an action satisfying every requirement compiles" do
    assert verifier_errors("""
           ash_quick do
             lookup do
               action :index
             end
           end

           actions do
             read :index do
               argument :search, :string
               #{@paginated}
             end
           end
           """) == []
  end

  test "a resource declaring no lookup block is not asked for one" do
    # The scoping decision, pinned. This resource has no `:index` at all — the
    # shape of every composite-keyed join resource and every child resource
    # nothing lists. Requiring one here would demand an action from resources
    # no dropdown or QuickView will ever call it on.
    assert verifier_errors("""
           actions do
             defaults [:read]
           end
           """) == []
  end
end
