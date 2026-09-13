defmodule AshQuick.Bookkeeping.Transformer do
  @moduledoc false
  # Adds the bookkeeping fields a resource declared and does not already define:
  # the two timestamps, the two `belongs_to` relationships to the configured
  # actor resource, and the `relate_actor` changes that stamp them.
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
  alias Spark.Dsl.Transformer

  # The fields have to exist before anything reading them runs.
  @impl true
  def after?(_), do: false

  @impl true
  def before?(_), do: true

  @impl true
  def transform(dsl_state) do
    {:ok,
     dsl_state
     |> add_timestamp(:created_at, :create_timestamp)
     |> add_timestamp(:updated_at, :update_timestamp)
     |> add_actor(:created_by)
     |> add_actor(:updated_by)
     # `:created_by` on create only; `:updated_by` on every write, which is why
     # a create stamps both. `:updated_by` passes no `on:` at all rather than a
     # list of its own — the option has a default, and naming the types here
     # would fix them at whatever they are today.
     |> add_relate_actor(:created_by, on: [:create])
     |> add_relate_actor(:updated_by, [])}
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

  # Nothing is added when the host configures no actor resource — a resource
  # then declares `created_by false` and carries none, which the verifier checks.
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
  # resource. Nothing but the name says a `belongs_to :created_by` is about the
  # actor, and stamping one that points elsewhere would write the actor's id
  # into a foreign key against another table. `AshQuick.Bookkeeping.Verifier`
  # refuses that resource outright, so this is what keeps the two consistent
  # rather than the only thing standing in the way.
  defp add_relate_actor(dsl_state, key, opts) do
    with name when not is_nil(name) <- Declaration.field(dsl_state, key),
         false <- stamped?(dsl_state, name),
         true <- actor_relationship?(dsl_state, name) do
      # Built through the builtin rather than as a literal tuple, so the
      # generated change carries exactly what the hand-written
      # `change relate_actor(:created_by)` carried — `allow_nil?: false`
      # included, which a literal would have quietly dropped.
      {:ok, change} =
        Transformer.build_entity(
          Dsl,
          [:changes],
          :change,
          Keyword.put(opts, :change, Builtins.relate_actor(name))
        )

      Transformer.add_entity(dsl_state, [:changes], change, type: :append)
    else
      _ -> dsl_state
    end
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

  defp relates_actor?(_change, _name), do: false
end
