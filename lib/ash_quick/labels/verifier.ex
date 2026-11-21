defmodule AshQuick.Labels.Verifier do
  @moduledoc false
  # Refuses a `label` the resource could never draw: one naming no field,
  # relationship, action or argument of the resource, one labelling a value
  # its field does not offer, or a name or value labelled twice. A label that
  # names nothing is a typo, and would leave the humanized name drawn with no
  # sign of why. A `help` naming nothing a form draws, scoped to an action
  # that is not there or draws no such input, or given twice for one name and
  # action, is refused for the same reason.

  use Spark.Dsl.Verifier

  alias AshQuick.LiveView.EnumOptions
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    entities = Verifier.get_entities(dsl_state, [:ash_quick, :labels])
    labels = Enum.filter(entities, &match?(%AshQuick.Labels.Label{}, &1))
    helps = Enum.filter(entities, &match?(%AshQuick.Labels.Help{}, &1))

    labels
    |> Enum.map(&problem(dsl_state, &1))
    |> Enum.concat(duplicates(labels))
    |> Enum.map(&{:label, &1})
    |> Enum.concat(helps |> Enum.map(&help_problem(dsl_state, &1)) |> Enum.map(&{:help, &1}))
    |> Enum.concat(Enum.map(help_duplicates(helps), &{:help, &1}))
    |> Enum.reject(&match?({_entity, nil}, &1))
    |> case do
      [] ->
        :ok

      [{entity, message} | _] ->
        {:error,
         Spark.Error.DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:ash_quick, :labels, entity],
           message: message
         )}
    end
  end

  # Help is drawn under a form input, so it has to name something a form
  # draws one for: an attribute, a relationship or an action argument, and,
  # scoped to an action, one that action's form draws. Blank help would draw
  # an empty line the input still points at.
  defp help_problem(dsl_state, %{name: name, help: help, action: action}) do
    cond do
      String.trim(help) == "" ->
        """
        `help #{inspect(name)}` is blank. Leave the entry out to draw no \
        help under its input.
        """

      problem = unknown_help(dsl_state, name) ->
        problem

      action ->
        action_problem(dsl_state, name, action)

      true ->
        nil
    end
  end

  defp unknown_help(dsl_state, name) do
    names =
      Enum.map(
        Verifier.get_entities(dsl_state, [:attributes]) ++
          relationships(dsl_state) ++
          Enum.flat_map(actions(dsl_state), &Map.get(&1, :arguments, [])),
        & &1.name
      )

    if name not in names do
      """
      `help #{inspect(name)}` names no attribute, relationship or action \
      argument of this resource, so no form draws an input it could help.
      """
    end
  end

  defp action_problem(dsl_state, name, action_name) do
    case Enum.find(actions(dsl_state), &(&1.name == action_name)) do
      nil ->
        """
        `help #{inspect(name)}, action: #{inspect(action_name)}` names no \
        action of this resource.
        """

      action ->
        if name not in form_inputs(dsl_state, action) do
          """
          `help #{inspect(name)}, action: #{inspect(action_name)}`: the \
          #{inspect(action_name)} form draws no input #{inspect(name)}. \
          Only a create, update or destroy action's accepted attributes, \
          their `belongs_to` relationships, and its arguments are drawn.
          """
        end
    end
  end

  # What the form of `action` draws an input for, as `Utils.action_fields/2`
  # walks it: the accepted attributes, a `belongs_to` in place of its source
  # attribute (either name takes the help), and the arguments.
  defp form_inputs(dsl_state, %{type: type} = action) when type in [:create, :update, :destroy] do
    accepted = List.wrap(Map.get(action, :accept))

    belongs_to =
      for %{type: :belongs_to, source_attribute: attribute, name: name} <-
            relationships(dsl_state),
          attribute in accepted,
          do: name

    accepted ++ belongs_to ++ Enum.map(action.arguments, & &1.name)
  end

  defp form_inputs(_dsl_state, _action), do: []

  defp help_duplicates(helps) do
    helps
    |> Enum.frequencies_by(&{&1.name, &1.action})
    |> Enum.filter(fn {_key, count} -> count > 1 end)
    |> Enum.map(fn
      {{name, nil}, _count} ->
        "`#{inspect(name)}` has more than one `help` without `action:`."

      {{name, action}, _count} ->
        "`#{inspect(name)}` has more than one `help` for `action: #{inspect(action)}`."
    end)
  end

  defp problem(dsl_state, %{name: name, value: nil}) do
    names =
      Enum.map(fields(dsl_state) ++ relationships(dsl_state), & &1.name) ++
        Enum.map(actions(dsl_state), & &1.name)

    if name not in names do
      """
      `label #{inspect(name)}` names no attribute, calculation, aggregate, \
      relationship, action or action argument of this resource.
      """
    end
  end

  defp problem(dsl_state, %{name: name, value: value}) do
    case Enum.filter(fields(dsl_state), &(&1.name == name)) do
      [] ->
        """
        `label #{inspect(name)}, #{inspect(value)}` labels a value of \
        #{inspect(name)}, which is no attribute, calculation, aggregate or \
        action argument of this resource.
        """

      fields ->
        offered = Enum.map(fields, &EnumOptions.values/1)

        if nil not in offered and value not in List.flatten(offered) do
          """
          `label #{inspect(name)}, #{inspect(value)}` labels a value \
          #{inspect(name)} does not offer. It offers \
          #{offered |> List.flatten() |> Enum.uniq() |> Enum.map_join(", ", &inspect/1)}.
          """
        end
    end
  end

  defp duplicates(labels) do
    labels
    |> Enum.frequencies_by(&{&1.name, &1.value})
    |> Enum.filter(fn {_key, count} -> count > 1 end)
    |> Enum.map(fn
      {{name, nil}, _count} ->
        "`#{inspect(name)}` is labelled more than once."

      {{name, value}, _count} ->
        "Value #{inspect(value)} of `#{inspect(name)}` is labelled more than once."
    end)
  end

  # What a value can belong to: a field, or an input of an action.
  defp fields(dsl_state) do
    Verifier.get_entities(dsl_state, [:attributes]) ++
      Verifier.get_entities(dsl_state, [:calculations]) ++
      Verifier.get_entities(dsl_state, [:aggregates]) ++
      Enum.flat_map(actions(dsl_state), &Map.get(&1, :arguments, []))
  end

  defp relationships(dsl_state), do: Verifier.get_entities(dsl_state, [:relationships])

  defp actions(dsl_state), do: Verifier.get_entities(dsl_state, [:actions])
end
