defmodule AshQuick.Labels.Verifier do
  @moduledoc false
  # Refuses a `label` the resource could never draw: one naming no field,
  # relationship, action or argument of the resource, one labelling a value
  # its field does not offer, or a name or value labelled twice. A label that
  # names nothing is a typo, and would leave the humanized name drawn with no
  # sign of why.

  use Spark.Dsl.Verifier

  alias AshQuick.LiveView.EnumOptions
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    labels = Verifier.get_entities(dsl_state, [:ash_quick, :labels])

    labels
    |> Enum.map(&problem(dsl_state, &1))
    |> Enum.concat(duplicates(labels))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        :ok

      [message | _] ->
        {:error,
         Spark.Error.DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:ash_quick, :labels, :label],
           message: message
         )}
    end
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
