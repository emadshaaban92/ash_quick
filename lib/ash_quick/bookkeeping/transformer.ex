defmodule AshQuick.Bookkeeping.Transformer do
  @moduledoc false
  # Adds the bookkeeping fields a resource declared and does not already define:
  # the two timestamps, the two `belongs_to` relationships to the configured
  # actor resource, and the changes that stamp them: `relate_actor` on create,
  # and `AshQuick.Bookkeeping.StampWriter` on an update, which stamps only a
  # write that changes something besides bookkeeping.
  #
  # Add-if-absent throughout, and each of the five pieces is checked on its own.
  # A resource keeping its own `belongs_to :updated_by` keeps it whole — the
  # attribute is not separately generated underneath it, which is what makes a
  # `define_attribute? false` relationship over a hand-written column survive.
  #
  # The variations this leaves alone are real and load-bearing: a resource may
  # keep `public? false` actor relationships, stamp only on update, pass
  # `allow_nil?` through to `relate_actor`, or stamp inside a single action
  # rather than globally. None of that is expressible in the declaration, and
  # none of it needs to be: skipping is the whole mechanism.
  use Spark.Dsl.Transformer

  alias Ash.Resource.Change
  alias Ash.Resource.Change.Builtins
  alias Ash.Resource.Dsl
  alias Ash.Resource.Info
  alias AshQuick.Bookkeeping.Declaration
  alias AshQuick.Bookkeeping.StampWriter
  alias AshQuick.Versioning.Declaration, as: VersioningDeclaration
  alias Spark.Dsl.Transformer

  # The fields have to exist before anything reading them runs. The stamps come
  # after the audit change and before the optimistic lock in every resource's
  # change list, so this runs after `AshQuick.Audit.Transformer` and before
  # `AshQuick.Versioning.Transformer`, which says so itself. Every one of the
  # three asks to run before everything, so without the pair named here Spark
  # leaves their order to chance.
  @impl true
  def after?(AshQuick.Audit.Transformer), do: true
  def after?(_), do: false

  @impl true
  def before?(AshQuick.Audit.Transformer), do: false
  def before?(_), do: true

  @impl true
  def transform(dsl_state) do
    with :ok <- refuse_writable_actor_columns(dsl_state) do
      {:ok,
       dsl_state
       |> add_timestamp(:inserted_at, :create_timestamp)
       |> add_timestamp(:updated_at, :update_timestamp)
       |> add_actor(:inserted_by)
       |> add_actor(:updated_by)
       # `:inserted_by` on create only; `:updated_by` on every create and on
       # every meaningful update, which is why a create stamps both.
       |> add_relate_actor(:inserted_by)
       |> add_relate_actor(:updated_by)}
    end
  end

  # A hand-written actor `belongs_to` keeps whatever it was declared with, and
  # a writable column lets a client name anyone as the writer through an
  # action accepting it — `accept :*` is enough. An update sending only the
  # column is not meaningful, so the stamp never replaces it, and nothing
  # re-stamps `inserted_by` after the create.
  #
  # Refused here rather than in `AshQuick.Bookkeeping.Verifier`: Spark reports
  # a verifier's error as a compile warning, and this one has to fail the build
  # whatever the host compiles with. Only the column is checked: a writable
  # relationship is reached only through an argument the host manages onto it
  # by name, which is a choice and not an accident. A relationship pointing
  # elsewhere is the verifier's to report, and is not stamped.
  defp refuse_writable_actor_columns(dsl_state) do
    case Enum.flat_map(Declaration.actors(), &writable_actor_column(dsl_state, &1)) do
      [] -> :ok
      problems -> {:error, writable_actor_error(dsl_state, problems)}
    end
  end

  defp writable_actor_column(dsl_state, key) do
    with name when not is_nil(name) <- Declaration.field(dsl_state, key),
         %{type: :belongs_to, destination: destination} = relationship <-
           Info.relationship(dsl_state, name),
         true <- Declaration.actor_destination?(destination),
         true <- column_writable?(dsl_state, relationship) do
      [{key, name, relationship.source_attribute}]
    else
      _ -> []
    end
  end

  # A `belongs_to` defining its column generates it later, from
  # `attribute_writable?`, which Ash has already defaulted to `writable?`.
  defp column_writable?(_dsl_state, %{define_attribute?: true} = relationship),
    do: relationship.attribute_writable?

  defp column_writable?(dsl_state, relationship) do
    case Info.attribute(dsl_state, relationship.source_attribute) do
      %{writable?: writable?} -> writable?
      nil -> false
    end
  end

  defp writable_actor_error(dsl_state, problems) do
    module = Transformer.get_persisted(dsl_state, :module)

    Spark.Error.DslError.exception(
      module: module,
      path: [:ash_quick, :bookkeeping],
      message: """
      #{inspect(module)} lets an action write who wrote a record:

      #{Enum.map_join(problems, "\n", &describe_writable/1)}

      A writable column lets a client name anyone as the record's writer \
      through any action accepting it, and the stamp does not overwrite an \
      update that writes only that. Add `writable?: false` to the `belongs_to` \
      when it defines the column, and drop any `attribute_writable? true` \
      there, or add it to the attribute under a `define_attribute? false` \
      one. AshQuick generates its actor relationships that way.
      """
    )
  end

  defp describe_writable({key, name, column}) do
    "  #{key} names #{inspect(name)}, whose column #{inspect(column)} is writable"
  end

  # `always_select?` for the same reason `:active` and `:version` carry it: a
  # details header reads the timestamp off a record whose select list came from
  # the QuickView's `fields:` option, which need not mention it.
  # `AshQuick.Bookkeeping.Verifier` holds hand-written timestamps to the same
  # rule, so the guarantee does not depend on which resources were generated.
  defp add_timestamp(dsl_state, key, entity) do
    case Declaration.field(dsl_state, key) do
      nil ->
        dsl_state

      name ->
        if Info.attribute(dsl_state, name) do
          dsl_state
        else
          {:ok, attribute} =
            Transformer.build_entity(Dsl, [:attributes], entity,
              name: name,
              public?: true,
              always_select?: true
            )

          Transformer.add_entity(dsl_state, [:attributes], attribute, type: :append)
        end
    end
  end

  # Not writable, so no action can accept the column — `accept :*` included —
  # and no argument can manage the relationship: who wrote a record is the
  # stamp's to say, never the client's. Writable, an update sending only the
  # column is not meaningful, so the stamp never replaces what it sent, and
  # nothing re-stamps `:inserted_by` after the create. The stamps write the
  # column with `force_change_attribute/3`, which writability does not govern.
  # `refuse_writable_actor_columns/1` holds hand-written actor columns to the
  # same rule.
  #
  # Nothing is added when the host configures no actor resource — a resource
  # then declares `inserted_by false` and carries none, which the verifier checks.
  #
  # The relationship crosses domains, so it needs the destination's. Read off
  # the actor resource rather than configured beside it: a second key could name
  # a domain the resource does not belong to, and there is nothing to check it
  # against. Dispatched through a variable, so no resource picks up a
  # compile-time dependency on the actor resource; `nil` comes back only while
  # the actor resource generates its *own* relationship, where it is also the
  # right answer — a self-referential relationship does not cross domains.
  defp add_actor(dsl_state, key) do
    with name when not is_nil(name) <- Declaration.field(dsl_state, key),
         nil <- Info.relationship(dsl_state, name),
         destination when not is_nil(destination) <- AshQuick.Config.actor_resource() do
      {:ok, relationship} =
        Transformer.build_entity(Dsl, [:relationships], :belongs_to,
          name: name,
          destination: destination,
          domain: Ash.Resource.Info.domain(destination),
          public?: true,
          writable?: false,
          allow_nil?: false
        )

      Transformer.add_entity(dsl_state, [:relationships], relationship, type: :append)
    else
      _ -> dsl_state
    end
  end

  # Skipped when the resource stamps this relationship anywhere at all, global
  # block or single action. Checking only the global block would double-stamp
  # the two resources that stamp inside one action, and would silently widen
  # them to every create the resource has.
  #
  # Also skipped when the relationship points somewhere other than the actor
  # resource. Nothing but the name says a `belongs_to :inserted_by` is about the
  # actor, and stamping one that points elsewhere would write the actor's id
  # into a foreign key against another table. `AshQuick.Bookkeeping.Verifier`
  # refuses that resource outright, so this is what keeps the two consistent
  # rather than the only thing standing in the way.
  defp add_relate_actor(dsl_state, key) do
    with name when not is_nil(name) <- Declaration.field(dsl_state, key),
         false <- stamped?(dsl_state, name),
         true <- actor_relationship?(dsl_state, name) do
      Enum.reduce(stamps(dsl_state, key, name), dsl_state, fn {change, on}, dsl_state ->
        # `relate_actor` is built through the builtin rather than as a literal
        # tuple, so the generated change carries exactly what the hand-written
        # `change relate_actor(:inserted_by)` carried — `allow_nil?: false`
        # included, which a literal would have quietly dropped.
        {:ok, change} =
          Transformer.build_entity(Dsl, [:changes], :change, change: change, on: on)

        Transformer.add_entity(dsl_state, [:changes], change, type: :append)
      end)
    else
      _ -> dsl_state
    end
  end

  defp stamps(_dsl_state, :inserted_by, name), do: [{Builtins.relate_actor(name), [:create]}]

  # An update stamps `:updated_by` only when it is meaningful — when it changes
  # something besides bookkeeping — so a write that changes nothing names
  # nobody as its writer and leaves `:updated_at` alone. See
  # `AshQuick.Bookkeeping.StampWriter`. It writes the foreign key, so it takes
  # a `belongs_to`; any other kind keeps `relate_actor/1` on every update.
  #
  # The lock's counter is passed in because the lock sets it after this has
  # run on the atomic path, and a write meaningful to one is meaningful to the
  # other.
  defp stamps(dsl_state, :updated_by, name) do
    case Info.relationship(dsl_state, name) do
      %{type: :belongs_to} ->
        [
          {Builtins.relate_actor(name), [:create]},
          {{StampWriter, relationship: name, ignore: lock_counter(dsl_state)}, [:update]}
        ]

      _ ->
        [{Builtins.relate_actor(name), [:create, :update]}]
    end
  end

  defp lock_counter(dsl_state) do
    if VersioningDeclaration.enabled?(dsl_state),
      do: [VersioningDeclaration.attribute(dsl_state)],
      else: []
  end

  defp actor_relationship?(dsl_state, name) do
    case Info.relationship(dsl_state, name) do
      nil -> false
      %{destination: destination} -> Declaration.actor_destination?(destination)
    end
  end

  defp stamped?(dsl_state, name) do
    global = Transformer.get_entities(dsl_state, [:changes])

    action_level =
      dsl_state
      |> Transformer.get_entities([:actions])
      |> Enum.flat_map(&Map.get(&1, :changes, []))

    Enum.any?(global ++ action_level, &relates_actor?(&1, name))
  end

  defp relates_actor?(%{change: {Change.RelateActor, opts}}, name) do
    Keyword.get(opts, :relationship) == name
  end

  defp relates_actor?(%{change: {StampWriter, opts}}, name) do
    Keyword.get(opts, :relationship) == name
  end

  defp relates_actor?(_change, _name), do: false
end
