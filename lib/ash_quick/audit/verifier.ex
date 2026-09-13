defmodule AshQuick.Audit.Verifier do
  @moduledoc false
  # Refuses to compile a resource that audits with no usable store behind it.
  #
  # Auditing is on by default, and there is deliberately no degraded mode to
  # fall back to: a resource whose store is missing, names nothing, is not a
  # resource, or cannot take the row, compiles clean today and then fails on
  # every create, update and destroy — from inside the action's transaction,
  # across the resource's whole surface. Over-auditing is cheap and reversible;
  # under-auditing is discovered by whoever needed the log and did not have it,
  # so the gap belongs at compile time, against the configuration that caused
  # it rather than against whoever next saves a record.
  #
  # Keyed on the attached change rather than on the declaration, so both routes
  # into auditing are covered at once: `AshQuick.Audit.Transformer` has already
  # appended it by the time verifiers run, and a resource auditing only some of
  # its actions attaches it by hand without entering the section at all. That
  # also means the resources the transformer never attaches to — the store
  # itself, embedded resources — are not asked for a store of their own.
  #
  # Only the *presence and shape* of the store are settled here — which store a
  # write goes to is still read per write, since nothing about a resource's
  # compiled form depends on it. A host configuring `:audit_resource` in
  # `runtime.exs` therefore has to move it to `config.exs`, the same constraint
  # `AshQuick.Bookkeeping.Verifier` already puts on `:actor_resource`.
  use Spark.Dsl.Verifier

  alias AshQuick.Audit.Declaration
  alias AshQuick.Audit.Row
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    if audits?(dsl_state) do
      dsl_state |> Declaration.store() |> check(dsl_state)
    else
      :ok
    end
  end

  defp check(nil, dsl_state), do: {:error, error(dsl_state, no_store())}

  # `:nofile` is a name that resolves to nothing — a typo in `config.exs` or in
  # `store`, which is the likeliest way to reach this verifier at all and is
  # caught nowhere else: the schema's `{:spark, Ash.Resource}` takes an
  # unresolvable module without complaint. Every other reason is a module that
  # exists and the compiler could not produce, which is not this verifier's to
  # report — answering that with a message about auditing would bury the error
  # that actually happened.
  #
  # The store is reached through a variable, so no resource picks up a tracked
  # compile-time dependency on it — but the answer still needs it compiled, and
  # `ensure_compiled/1` is what waits for the parallel compiler instead of
  # reading a module that is not there yet.
  defp check(store, dsl_state) do
    case Code.ensure_compiled(store) do
      {:module, _module} -> check_resource(store, dsl_state)
      {:error, :nofile} -> {:error, error(dsl_state, no_such_module(store))}
      {:error, _reason} -> :ok
    end
  end

  defp check_resource(store, dsl_state) do
    if Ash.Resource.Info.resource?(store) do
      check_create(store, dsl_state)
    else
      {:error, error(dsl_state, not_a_resource(store))}
    end
  end

  # A store is written through its `:create` action, so one without it takes no
  # row at all — reported as itself rather than as every column an action that
  # is not there does not accept.
  defp check_create(store, dsl_state) do
    case Ash.Resource.Info.action(store, :create) do
      nil -> {:error, error(dsl_state, no_create_action(store))}
      action -> check_fields(store, action, dsl_state)
    end
  end

  defp check_fields(store, action, dsl_state) do
    missing = Enum.reject(Row.fields(), &Ash.Resource.Info.attribute(store, &1))
    refused = Row.fields() -- (missing ++ accepted(action))

    if missing == [] and refused == [] do
      :ok
    else
      {:error, error(dsl_state, unwritable(store, missing, refused))}
    end
  end

  # A column the store has but its `:create` will not take is the same failure
  # one write later — `NoSuchInput`, on a private attribute `accept :*` skips.
  # An argument of that name is taking it too: a store relating its actor takes
  # `actor_id` through one rather than through `accept`.
  defp accepted(%{accept: accept, arguments: arguments}) do
    accept ++ Enum.map(arguments, & &1.name)
  end

  defp audits?(dsl_state) do
    Enum.any?(Ash.Resource.Info.changes(dsl_state), &audit_change?/1) or
      Enum.any?(Ash.Resource.Info.actions(dsl_state), fn action ->
        Enum.any?(Map.get(action, :changes) || [], &audit_change?/1)
      end)
  end

  defp audit_change?(%{change: {AshQuick.Audit.Change, _opts}}), do: true
  defp audit_change?(_change), do: false

  defp error(dsl_state, {problem, remedy}) do
    module = Verifier.get_persisted(dsl_state, :module)

    Spark.Error.DslError.exception(
      module: module,
      path: [:ash_quick, :audit],
      message: """
      #{inspect(module)} is audited, and #{problem}

      Every create, update and destroy on it writes its entry there, so without \
      a usable one the resource does not fail here — it fails on every write, \
      inside the action's transaction.

      #{remedy}
      Or stop auditing this resource, which is a decision to keep no record of \
      who changed it:

          ash_quick do
            audit do
              enabled? false
            end
          end

      Where the change is attached to individual actions instead, remove \
      `change AshQuick.Audit.Change` from them.
      """
    )
  end

  defp no_store do
    {"""
     there is no audit store to write to.
     """,
     """
     Generate one, with its domain and its migration:

         mix igniter.install ash_quick

     or point AshQuick at a store you already have, where compilation can see \
     it — in `config.exs` rather than `runtime.exs`:

         config :ash_quick, audit_resource: MyApp.AuditLog

     or per resource, for one that records elsewhere:

         ash_quick do
           audit do
             store MyApp.SecurityLog
           end
         end
     """}
  end

  defp no_such_module(store) do
    {"""
     the configured store #{inspect(store)} does not exist.
     """,
     """
     Check the name against the store you meant, and configure it where \
     compilation can see it — in `config.exs` rather than `runtime.exs`:

         config :ash_quick, audit_resource: MyApp.AuditLog

     or per resource, for one that records elsewhere:

         ash_quick do
           audit do
             store MyApp.SecurityLog
           end
         end

     If there is no store to name yet, generate one, with its domain and its \
     migration:

         mix igniter.install ash_quick
     """}
  end

  defp no_create_action(store) do
    {"""
     the store #{inspect(store)} has no `:create` action to write the row through.
     """,
     """
     AshQuick bulk-inserts every entry through #{inspect(store)}'s `:create` \
     action, so it needs one accepting #{fields(Row.fields())}. Add it, or \
     regenerate the store:

         mix igniter.install ash_quick
     """}
  end

  defp not_a_resource(store) do
    {"""
     the configured store #{inspect(store)} is not an Ash resource.
     """,
     """
     An audit store is a resource with a `:create` action AshQuick bulk-inserts \
     into. `mix igniter.install ash_quick` generates one.
     """}
  end

  defp unwritable(store, missing, refused) do
    {"""
     the store #{inspect(store)} cannot take the row: #{describe(missing, refused)}
     """,
     """
     AshQuick fills #{fields(Row.fields())} on every entry, and writes them \
     through #{inspect(store)}'s `:create` action, so a store that is short one \
     of them refuses the whole batch. Add what is missing to #{inspect(store)}, \
     or regenerate it:

         mix igniter.install ash_quick
     """}
  end

  defp describe([], refused), do: "its `:create` action does not accept #{fields(refused)}."

  defp describe(missing, []), do: "it has no #{fields(missing)}."

  defp describe(missing, refused) do
    "it has no #{fields(missing)}, and its `:create` action does not accept #{fields(refused)}."
  end

  defp fields(names), do: Enum.map_join(names, ", ", &"`#{&1}`")
end
