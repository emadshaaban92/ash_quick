defmodule AshQuick.Bookkeeping.Verifier do
  @moduledoc false
  # Refuses to compile a resource whose bookkeeping declaration does not match
  # the fields it actually has, in either direction.
  #
  # Nothing generates these fields, so the declaration is worth something only
  # if it is checked. Both directions matter, and for the same reason —
  # `AshQuick.Config.versioning_ignored_attributes/1` is derived from what was
  # declared:
  #
  #   * A field declared but absent puts a name that no changeset can carry into
  #     the ignore list. Harmless today, but it is a claim about the resource
  #     that later readers (a details header, an export) would act on.
  #
  #   * A field declared absent but *present* leaves a real bookkeeping column
  #     out of the ignore list, so touching it counts as a meaningful change and
  #     the optimistic lock bumps `version` on a write that used to be a no-op.
  #     Silent, and the reason this check is bidirectional rather than a
  #     convenience.
  #
  # An actor field satisfies its declaration only if it is a relationship to the
  # configured actor resource. The name alone means nothing — `belongs_to
  # :created_by, Seller` is a relationship to a seller — and the transformer
  # stamps the actor into whatever the declaration names, so one pointing
  # elsewhere would take a user's id into a foreign key against another table.
  # A resource that has such a relationship declares the field absent and keeps
  # it; that also drops its column from the ignore list, which is right, since a
  # change to it is a change to the record.
  #
  # A third check covers `always_select?` on the timestamps. The transformer puts
  # it on every timestamp it generates, but add-if-absent means a hand-written one
  # keeps whatever it was declared with — so without this the guarantee would hold
  # for most resources and quietly not for the rest, which is the worst shape for
  # something a generic details header reads.
  #
  # Every mismatch is reported at once: a resource declaring nothing and having
  # none of the four should learn that in one compile, not four.
  #
  # Checked before any of that: a resource stamping an actor needs the actor
  # resource to carry the AshQuick extension, because that is what resolves what
  # one of its records is called and a details header renders the actor by
  # loading exactly that. Without it the header has no label to ask for, and the
  # failure lands on every details page in the app rather than on the
  # configuration that caused it. Reported here, on a resource that stamps one,
  # since that is what the requirement is about — a host that stamps no actor
  # configures none and never reaches this.
  use Spark.Dsl.Verifier

  alias AshQuick.Bookkeeping.Declaration
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    with :ok <- verify_actor_resource(dsl_state) do
      verify_fields(dsl_state)
    end
  end

  defp verify_fields(dsl_state) do
    problems =
      Enum.flat_map(Declaration.timestamps() ++ Declaration.actors(), &problem(dsl_state, &1)) ++
        Enum.flat_map(Declaration.timestamps(), &always_select_problem(dsl_state, &1))

    case problems do
      [] -> :ok
      problems -> {:error, error(dsl_state, problems)}
    end
  end

  # Only a resource that actually stamps an actor depends on the actor resource
  # naming its records; one declaring both fields absent is unaffected. A host
  # configuring none stamps nothing, so no relationship satisfies an actor
  # declaration and this never fires.
  defp verify_actor_resource(dsl_state) do
    destination = AshQuick.Config.actor_resource()

    if stamps_actor?(dsl_state) and not labelling_extension?(dsl_state, destination) do
      {:error, actor_resource_error(dsl_state, destination)}
    else
      :ok
    end
  end

  defp stamps_actor?(dsl_state) do
    Enum.any?(Declaration.actors(), fn key ->
      case Declaration.field(dsl_state, key) do
        nil -> false
        name -> actor_status(dsl_state, name) == :ok
      end
    end)
  end

  # The actor resource is reached through a variable, so no resource picks up a
  # tracked compile-time dependency on it — but the answer still needs it
  # compiled, and `ensure_compiled/1` is what waits for the parallel compiler
  # instead of reading a module that is not there yet.
  #
  # A module the compiler cannot produce is not this verifier's to report. Ash's
  # own relationship validation covers a destination that does not exist, and
  # failing here would answer a compile cycle with a message about extensions.
  #
  # The actor resource stamps itself, and while it does it is the module under
  # verification: its own DSL state is the answer, and asking the compiler for a
  # module it is in the middle of building would deadlock.
  defp labelling_extension?(dsl_state, destination) do
    if Verifier.get_persisted(dsl_state, :module) == destination do
      AshQuick in Spark.extensions(dsl_state)
    else
      case Code.ensure_compiled(destination) do
        {:module, _} -> AshQuick in Spark.extensions(destination)
        {:error, _} -> true
      end
    end
  end

  # `{:missing, key, name}` — declared, not there. `{:undeclared, key, name}` —
  # there, declared absent. `{:foreign_actor, key, name, destination}` — an
  # actor relationship of that name, pointing at something other than the actor.
  # The name travels with the problem so the message does not have to resolve it
  # again.
  defp problem(dsl_state, key) do
    case Declaration.field(dsl_state, key) do
      nil ->
        default = Declaration.default(key)

        # Only a field that would have *satisfied* the declaration counts as
        # undeclared. A foreign `:created_by` disclaimed is the escape hatch for
        # a resource that has one, so it cannot also be an error.
        if status(dsl_state, key, default) == :ok, do: [{:undeclared, key, default}], else: []

      name ->
        case status(dsl_state, key, name) do
          :ok -> []
          :absent -> [{:missing, key, name}]
          {:foreign, destination} -> [{:foreign_actor, key, name, destination}]
        end
    end
  end

  # Only meaningful for a field that is declared and present — a missing one is
  # already reported, and reporting it twice helps nobody.
  defp always_select_problem(dsl_state, key) do
    with name when not is_nil(name) <- Declaration.field(dsl_state, key),
         %{always_select?: false} <- Ash.Resource.Info.attribute(dsl_state, name) do
      [{:not_always_select, key, name}]
    else
      _ -> []
    end
  end

  defp status(dsl_state, :created_at, name), do: attribute_status(dsl_state, name)
  defp status(dsl_state, :updated_at, name), do: attribute_status(dsl_state, name)
  defp status(dsl_state, :created_by, name), do: actor_status(dsl_state, name)
  defp status(dsl_state, :updated_by, name), do: actor_status(dsl_state, name)

  defp attribute_status(dsl_state, name) do
    if Ash.Resource.Info.attribute(dsl_state, name), do: :ok, else: :absent
  end

  # A relationship of the right name is not enough — `AshQuick.Bookkeeping.Transformer`
  # stamps the actor into whatever the declaration names, so one pointing at
  # another resource would take a user's id into a foreign key against another
  # table.
  defp actor_status(dsl_state, name) do
    case Ash.Resource.Info.relationship(dsl_state, name) do
      nil ->
        :absent

      %{destination: destination} ->
        if Declaration.actor_destination?(destination), do: :ok, else: {:foreign, destination}
    end
  end

  defp actor_resource_error(dsl_state, destination) do
    module = Verifier.get_persisted(dsl_state, :module)

    Spark.Error.DslError.exception(
      module: module,
      path: [:ash_quick, :bookkeeping],
      message: """
      #{inspect(module)} stamps an actor, and the configured `:actor_resource` \
      #{inspect(destination)} does not carry the AshQuick extension.

      What one of its records is called is resolved by that extension, and a \
      details header renders who wrote a record by loading exactly that field \
      off the actor. Without it there is nothing to load, and every details \
      page in the app fails rather than this resource.

      Add the extension to the actor resource:

          use Ash.Resource,
            extensions: [AshQuick, ...]
      """
    )
  end

  defp error(dsl_state, problems) do
    module = Verifier.get_persisted(dsl_state, :module)

    Spark.Error.DslError.exception(
      module: module,
      path: [:ash_quick, :bookkeeping],
      message: """
      #{inspect(module)}'s bookkeeping declaration does not match the fields it has:

      #{Enum.map_join(problems, "\n", &describe/1)}

      All four default on, so a resource that does not carry one has to say so:

          ash_quick do
            bookkeeping do
      #{Enum.map_join(problems, "\n", &suggest/1)}
            end
          end

      A timestamp reported as not `always_select?: true` is a different fix: add \
      that option to the attribute itself. AshQuick generates its timestamps with \
      it, so this only reaches a resource writing its own — a generic details \
      header reads the field off records whose select list never mentioned it.

      An actor reported as pointing at another resource is what the opt-out above \
      is for: the declaration means the actor that wrote the record, and AshQuick \
      stamps the actor's id into whatever it names. A `belongs_to` of that name \
      meaning something else keeps its name and stays out of the declaration.
      """
    )
  end

  defp describe({:missing, key, name}) do
    "  #{key} is declared as #{inspect(name)}, which this resource does not define"
  end

  defp describe({:undeclared, key, name}) do
    "  #{key} defaults to #{inspect(name)}, which this resource defines but declares absent"
  end

  defp describe({:not_always_select, key, name}) do
    "  #{key} names #{inspect(name)}, which is not `always_select?: true`"
  end

  defp describe({:foreign_actor, key, name, destination}) do
    "  #{key} names #{inspect(name)}, which is a relationship to #{inspect(destination)} rather than to #{inspect(AshQuick.Config.actor_resource())}"
  end

  defp suggest({:missing, key, _name}), do: "        #{key} false"
  defp suggest({:undeclared, key, name}), do: "        #{key} #{inspect(name)}"
  defp suggest({:not_always_select, key, _name}), do: "        # (#{key}: see below)"
  defp suggest({:foreign_actor, key, _name, _destination}), do: "        #{key} false"
end
