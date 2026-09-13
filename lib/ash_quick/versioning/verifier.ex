defmodule AshQuick.Versioning.Verifier do
  @moduledoc false
  # Refuses to compile a resource whose locked attribute is not a lock counter.
  #
  # `AshQuick.Versioning.Transformer` adds the attribute only when the resource
  # does not already define one by that name, so a resource that owns a
  # `:version` meaning something else keeps its own definition and the lock
  # silently operates on it — filtering on a value it does not control and
  # incrementing it on every write. An extension that gives a resource a
  # `:version` meaning its event's schema version is exactly such a column; the
  # moment that resource takes on AshQuick, this is what stops it.
  #
  # Checked after the transformer, so a column AshQuick added passes by
  # construction and only a foreign one can fail.
  use Spark.Dsl.Verifier

  alias AshQuick.Versioning.Declaration
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    if Declaration.enabled?(dsl_state) do
      name = Declaration.attribute(dsl_state)

      dsl_state
      |> Ash.Resource.Info.attribute(name)
      |> mismatches()
      |> case do
        [] -> :ok
        mismatches -> {:error, error(dsl_state, name, mismatches)}
      end
    else
      :ok
    end
  end

  # `{option, actual, expected}` for every way the column differs, so the message
  # does not have to look the attribute up again to say what it found.
  defp mismatches(attribute) do
    Enum.flat_map(expected(), fn {option, expected} ->
      case Map.get(attribute, option) do
        ^expected -> []
        actual -> [{option, actual, expected}]
      end
    end)
  end

  # The shape the transformer builds, with `:type` resolved the way a compiled
  # attribute carries it — `:integer` on the way in, `Ash.Type.Integer` back out.
  defp expected do
    Keyword.update!(Declaration.counter(), :type, &Ash.Type.get_type/1)
  end

  defp error(dsl_state, name, mismatches) do
    module = Verifier.get_persisted(dsl_state, :module)

    Spark.Error.DslError.exception(
      module: module,
      path: [:ash_quick, :versioning],
      message: """
      #{inspect(module)} already defines `#{name}`, but not as an optimistic-lock counter:

      #{Enum.map_join(mismatches, "\n", fn {option, actual, expected} -> "  #{option} is #{inspect(actual)}, expected #{inspect(expected)}" end)}

      Versioning would filter writes on that column and increment it, which is \
      almost certainly not what it means here.

      Lock on a different column:

          ash_quick do
            versioning do
              attribute :lock_version
            end
          end

      or turn versioning off for this resource:

          ash_quick do
            versioning do
              enabled? false
            end
          end
      """
    )
  end
end
